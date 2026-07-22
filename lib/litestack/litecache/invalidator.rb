# frozen_string_literal: true

require "oj"
require "securerandom"

class Litecache
  # Cross-process L1 invalidation via Honker notify/listen on the cache DB file.
  #
  # Single channel (default "litecache") + JSON payload:
  #   { "op" => "set"|"delete"|"clear"|"mset", "key" => "...", "keys" => [...], "src" => instance_id }
  class Invalidator
    def initialize(cache, options:)
      @cache = cache
      @options = options
      @channel = (options[:notify_channel] || "litecache").to_s
      @instance_id = SecureRandom.hex(8)
      @extension_path = options[:honker_extension_path]
      @poll_ms = (options[:watcher_poll_interval_ms] || 5).to_i
      @notify_ops = Array(options[:notify_ops] || %i[set delete clear]).map(&:to_sym)
      @path = options[:path].to_s
      @db = nil
      @last_id = 0
      @running = false
      @thread = nil
      @enabled = false
    end

    attr_reader :instance_id, :enabled

    def setup!
      return false unless Litestack::Wakeup::Honker.watchable_path?(@path)
      return false unless Litestack::Wakeup::Honker.load_honker_gem!

      opts = {watcher_poll_interval_ms: [@poll_ms, 1].max}
      opts[:extension_path] = @extension_path if @extension_path
      @db = ::Honker::Database.new(@path, **opts)
      @last_id = @db.db.get_first_value(
        "SELECT COALESCE(MAX(id), 0) FROM _honker_notifications"
      ).to_i
      @running = true
      @enabled = true
      @thread = Thread.new { listen_loop }
      @thread.name = "litestack-litecache-invalidate" if @thread.respond_to?(:name=)
      true
    rescue => e
      @enabled = false
      warn "[litecache] honker invalidator disabled: #{e.class}: #{e.message}"
      close
      false
    end

    def notifies?(op)
      @enabled && @notify_ops.include?(op.to_sym)
    end

    # Run SQL notify on an open raw SQLite3 connection (same txn as L2 write).
    def notify_on_connection(conn, op:, key: nil, keys: nil)
      return unless notifies?(op)

      payload = {
        "op" => op.to_s,
        "src" => @instance_id
      }
      payload["key"] = key.to_s if key
      payload["keys"] = Array(keys).map(&:to_s) if keys
      conn.execute("SELECT notify(?, ?)", [@channel, Oj.dump(payload)])
    rescue => e
      @cache.instance_variable_get(:@logger)&.warn {
        "[litecache] notify failed: #{e.class}: #{e.message}"
      }
    end

    def close
      @running = false
      begin
        @db&.mark_updated
      rescue
        nil
      end
      if @thread&.alive?
        @thread.join(2)
        @thread.kill if @thread.alive?
      end
      @thread = nil
      begin
        @db&.close
      rescue
        nil
      end
      @db = nil
      @enabled = false
    end

    private

    def listen_loop
      while @running && @db
        begin
          drained = drain!
          @db.wait_for_update(drained ? 0.05 : 1.0) if @running
        rescue ::Honker::Error, SQLite3::Exception
          break unless @running
          sleep 0.05
        rescue => e
          break unless @running
          warn "[litecache] invalidator loop: #{e.class}: #{e.message}"
          sleep 0.1
        end
      end
    end

    def drain!
      rows = @db.db.execute(
        "SELECT id, payload FROM _honker_notifications " \
        "WHERE id > ? AND channel = ? ORDER BY id",
        [@last_id, @channel]
      )
      return false if rows.empty?

      rows.each do |id, payload_raw|
        @last_id = id.to_i
        apply_payload(payload_raw)
      end
      true
    end

    def apply_payload(raw)
      data = Oj.load(raw)
      return unless data.is_a?(Hash)
      return if data["src"] == @instance_id

      case data["op"].to_s
      when "set", "delete"
        k = data["key"]
        @cache.send(:l1_delete, k) if k
      when "mset"
        Array(data["keys"]).each { |k| @cache.send(:l1_delete, k) }
      when "clear"
        @cache.send(:l1_clear)
      end
    rescue Oj::ParseError
      nil
    end
  end
end
