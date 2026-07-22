# frozen_string_literal: true

require "yaml"
require "erb"
require "json"
require_relative "definition"

module Litestack
  module Recurring
    # Background ticker that enqueues due recurring tasks into Litejobqueue.
    #
    # Config (any one):
    #   options[:recurring]  => Hash of name => definition
    #   options[:recurring_path] => YAML file (default ./config/recurring.yml)
    #   litejob.yml key "recurring:" under the current environment
    #
    # Multi-process: uses Leadership lock "litestack:litejob:recurring" when Honker
    # is available; otherwise best-effort with SQLite unique slot keys.
    class Scheduler
      TABLE = "litestack_recurring"
      TICK_DEFAULT = 5

      def initialize(jobqueue, options = {})
        @jobqueue = jobqueue
        @options = options
        @definitions = load_definitions
        @tick = (options[:recurring_tick] || options[:recurring_poll_interval] || TICK_DEFAULT).to_f
        @tick = 5.0 if @tick <= 0
        @closed = false
        @leadership = nil
        ensure_table!
        setup_leadership!
      end

      def empty?
        @definitions.empty?
      end

      def definitions
        @definitions.dup
      end

      def tick!(now = Time.now)
        return if @closed || empty?

        if @leadership
          @leadership.with_lock { enqueue_due(now) }
        else
          enqueue_due(now)
        end
      end

      def close
        @closed = true
        begin
          @leadership&.close
        rescue
          nil
        end
        @leadership = nil
      end

      private

      def load_definitions
        raw = @options[:recurring]
        if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
          raw = load_from_yaml_file
        end
        raw = normalize_env_hash(raw)
        return [] if raw.nil? || raw.empty?

        raw.map { |name, h| Definition.from_hash(name, h) }
      rescue ArgumentError => e
        warn "[litestack] recurring config error: #{e.message}"
        []
      end

      def load_from_yaml_file
        path = @options[:recurring_path]
        path ||= begin
          candidates = [
            "./config/recurring.yml",
            "./recurring.yml",
            @options[:config_path] # may be litejob.yml — read recurring: key only
          ]
          candidates.find { |p| p && File.file?(p.to_s) }
        end
        return nil unless path && File.file?(path.to_s)

        doc = YAML.safe_load(ERB.new(File.read(path.to_s)).result, aliases: true) || {}
        # If this is litejob.yml, pull recurring: only
        if path.to_s.end_with?("litejob.yml") || path.to_s.include?("litejob")
          env = Litesupport.environment.to_s
          section = doc[env] || doc[env.to_sym] || doc
          return section.is_a?(Hash) ? (section["recurring"] || section[:recurring]) : nil
        end

        env = Litesupport.environment.to_s
        doc[env] || doc[env.to_sym] || doc["recurring"] || doc
      end

      def normalize_env_hash(raw)
        return raw if raw.is_a?(Hash) && raw.values.all? { |v| v.is_a?(Hash) }
        return raw["recurring"] || raw[:recurring] if raw.is_a?(Hash)

        nil
      end

      def setup_leadership!
        path = @options[:path]
        return if @options[:leadership] == false
        return unless path && Litestack::Wakeup::Honker.watchable_path?(path)

        @leadership = Litestack::Leadership.new(
          path: path,
          name: "litestack:litejob:recurring",
          ttl_s: @options[:leadership_ttl] || 30,
          extension_path: @options[:honker_extension_path],
          watcher_poll_interval_ms: @options[:watcher_poll_interval_ms]
        )
      rescue => e
        @leadership = nil
        warn "[litestack] recurring leadership unavailable: #{e.class}: #{e.message}"
      end

      def sql(sql, *args)
        @jobqueue.send(:run_sql, sql, *args)
      end

      def ensure_table!
        sql(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{TABLE} (
            name TEXT PRIMARY KEY NOT NULL,
            last_enqueued_at REAL,
            last_key TEXT
          ) WITHOUT ROWID
        SQL
      rescue => e
        warn "[litestack] recurring table: #{e.class}: #{e.message}"
      end

      def enqueue_due(now)
        count = 0
        @definitions.each do |defn|
          next unless defn.enabled

          row = load_row(defn.name)
          last_at = row && row[0]
          last_key = row && row[1]
          next unless defn.due?(now, last_at, last_key)

          key = defn.slot_key(now)
          # Claim the slot first (unique key) to avoid double enqueue races.
          next unless claim_slot(defn.name, now.to_f, key, last_key)

          begin
            enqueue_one(defn)
            count += 1
          rescue => e
            # Roll back slot so we retry next tick
            restore_slot(defn.name, last_at, last_key)
            warn "[litestack] recurring #{defn.name} enqueue failed: #{e.class}: #{e.message}"
          end
        end
        count
      end

      def load_row(name)
        rows = sql(
          "SELECT last_enqueued_at, last_key FROM #{TABLE} WHERE name = ?",
          name
        )
        rows&.first
      rescue
        nil
      end

      def claim_slot(name, at, key, _previous_key)
        row = load_row(name)
        return false if row && row[1].to_s == key.to_s

        sql(<<~SQL, name, at, key)
          INSERT INTO #{TABLE}(name, last_enqueued_at, last_key)
          VALUES (?, ?, ?)
          ON CONFLICT(name) DO UPDATE SET
            last_enqueued_at = excluded.last_enqueued_at,
            last_key = excluded.last_key
          WHERE #{TABLE}.last_key IS NOT excluded.last_key
             OR #{TABLE}.last_key IS NULL
        SQL
        row = load_row(name)
        row && row[1].to_s == key.to_s
      rescue => e
        warn "[litestack] recurring claim_slot: #{e.class}: #{e.message}"
        false
      end

      def restore_slot(name, last_at, last_key)
        if last_at.nil? && last_key.nil?
          sql("DELETE FROM #{TABLE} WHERE name = ?", name)
        else
          sql(
            "UPDATE #{TABLE} SET last_enqueued_at = ?, last_key = ? WHERE name = ?",
            last_at, last_key, name
          )
        end
      rescue
        nil
      end

      def enqueue_one(defn)
        if defn.command && !defn.command.to_s.empty?
          run_command(defn.command)
          return
        end

        klass = resolve_class(defn.klass)
        args = defn.args
        queue = defn.queue

        if defined?(ActiveJob::Base) && klass < ActiveJob::Base && klass.respond_to?(:set)
          klass.set(queue: queue).perform_later(*args)
        elsif defined?(ActiveJob::Base) && klass < ActiveJob::Base
          klass.perform_later(*args)
        else
          # Litejob / raw: push class name + params array
          @jobqueue.push(klass.name, args, 0, queue)
        end
      end

      def resolve_class(name)
        name.split("::").inject(Object) { |m, c| m.const_get(c) }
      end

      def run_command(command)
        # Same spirit as Solid Queue command: execute Ruby in the app process.
        # Prefer `class:` jobs in production; `command:` is for simple ops hooks.
        # standard:disable Security/Eval
        eval(command.to_s)
        # standard:enable Security/Eval
      end
    end
  end
end
