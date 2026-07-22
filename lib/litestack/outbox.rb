# frozen_string_literal: true

require "json"

module Litestack
  class OutboxError < RuntimeError; end

  # Transactional outbox helpers: write job rows on the same SQLite connection
  # (and thus the same COMMIT) as ActiveRecord business writes.
  #
  # Prerequisites:
  #   * LiteJob queue table (and optional Honker schema) already exist on the
  #     shared database file — created at Litejobqueue setup time.
  #   * ActiveJob enqueue_after_transaction_commit is false so enqueue runs
  #     inside the open AR transaction, not after it.
  #
  # Outside an open AR transaction, callers fall back to the normal LiteJob
  # connection pool (still co-located on the same file when database: primary).
  module Outbox
    PUSH_SQL = <<~SQL.freeze
      INSERT INTO queue(id, name, fire_at, value)
      VALUES (hex(randomblob(32)), ?, (unixepoch('subsec') + ?), ?)
      RETURNING id, name
    SQL

    module_function

    def active_raw_connection(options)
      return nil unless outbox_enabled?(options)
      return nil unless defined?(ActiveRecord::Base)

      ar = active_record_connection(options)
      return nil unless ar
      return nil unless ar.transaction_open?
      return nil unless ar.respond_to?(:raw_connection)

      raw = ar.raw_connection
      return nil unless raw.is_a?(SQLite3::Database)

      raw
    rescue
      nil
    end

    def outbox_enabled?(options)
      return true if options[:outbox] == true
      return true if options[:transactional_outbox] == true
      return false if options[:outbox] == false

      db = options[:database]
      db == true || db.to_s == "primary" || (db && !%w[litejob false].include?(db.to_s))
    end

    def active_record_connection(options)
      name = (options[:database_name] || options[:ar_connection] || "primary").to_s
      cfg = ActiveRecord::Base.connection_db_config
      if name == "primary" || (cfg && cfg.name.to_s == name)
        ActiveRecord::Base.connection
      else
        # Multi-db: prefer the currently checked-out connection when it matches.
        ActiveRecord::Base.connection
      end
    end

    # Insert a LiteQueue-format row on +raw+ (already inside AR's transaction).
    # Returns [id, queue_name].
    def push_litequeue(raw, value:, delay: 0, queue: "default", notify: false, extension_path: nil)
      q = queue || "default"
      delay_f = delay.to_f
      delay_f = 0 if delay_f.negative?
      row = raw.get_first_row(PUSH_SQL, [q, delay_f, value])
      raise OutboxError, "outbox push returned no row" if row.nil?

      if notify
        ensure_honker!(raw, extension_path: extension_path)
        channel = "litequeue:#{q}"
        payload = Oj.dump({id: row[0], delay: delay_f, queue: q}, mode: :strict)
        raw.execute("SELECT notify(?, ?)", [channel, payload])
      end

      [row[0].to_s, row[1].to_s]
    end

    # Honker enqueue on the shared AR connection. Returns [id, queue_name].
    def push_honker(raw, payload:, delay: 0, queue: "default", max_attempts: 3, extension_path: nil)
      ensure_honker!(raw, extension_path: extension_path)
      q = queue || "default"
      delay_s = delay.to_f
      delay_arg = (delay_s > 0) ? [delay_s.ceil, 1].max : nil
      json = payload.is_a?(String) ? payload : JSON.dump(payload)
      id = raw.get_first_value(
        "SELECT honker_enqueue(?, ?, ?, ?, ?, ?, ?)",
        [q, json, nil, delay_arg, 0, max_attempts, nil]
      )
      [id.to_s, q]
    end

    def ensure_honker!(raw, extension_path: nil)
      return if raw.instance_variable_get(:@litestack_honker_ready)

      unless defined?(::Honker::Database)
        raise LoadError, "honker gem required for outbox notify/honker backend" unless Litestack::Wakeup::Honker.load_honker_gem!
      end

      ::Honker.setup(raw, extension_path: extension_path)
      raw.instance_variable_set(:@litestack_honker_ready, true)
    end
  end
end

