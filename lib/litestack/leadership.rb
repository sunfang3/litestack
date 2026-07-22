# frozen_string_literal: true

require "securerandom"

module Litestack
  # Optional single-leader coordination for maintenance loops (GC, pruner).
  #
  # With Honker: advisory named lock so only one process runs the work.
  # Without Honker: every process is a "leader" (historical Litestack behaviour).
  class Leadership
    DEFAULT_TTL = 30

    class AlwaysHeld
      def release
        true
      end

      def heartbeat(*)
        true
      end

      def released?
        false
      end
    end

    def self.available?(path:)
      Litestack::Wakeup::Honker.available?(path: path)
    end

    def initialize(path:, name:, owner: nil, ttl_s: DEFAULT_TTL, extension_path: nil, watcher_poll_interval_ms: 5)
      @path = path.to_s
      @name = name.to_s
      @owner = owner || "litestack-#{Process.pid}-#{SecureRandom.hex(4)}"
      @ttl_s = ttl_s.to_i
      @ttl_s = DEFAULT_TTL if @ttl_s <= 0
      @extension_path = extension_path
      @watcher_poll_interval_ms = watcher_poll_interval_ms
      @db = nil
      @enabled = self.class.available?(path: @path)
      open_db! if @enabled
    end

    def enabled?
      @enabled
    end

    # Yields only while this process holds the lock. Returns true if work ran.
    def with_lock
      lock = try_acquire
      return false unless lock

      begin
        yield lock
        true
      ensure
        begin
          lock.release
        rescue
          nil
        end
      end
    end

    def try_acquire
      return AlwaysHeld.new unless @enabled && @db

      @db.try_lock(@name, owner: @owner, ttl_s: @ttl_s)
    rescue => e
      warn "[litestack] leadership acquire failed (#{@name}): #{e.class}: #{e.message}"
      nil
    end

    def close
      begin
        @db&.close
      rescue
        nil
      end
      @db = nil
    end

    private

    def open_db!
      return unless Litestack::Wakeup::Honker.load_honker_gem!

      opts = {watcher_poll_interval_ms: @watcher_poll_interval_ms}
      opts[:extension_path] = @extension_path if @extension_path
      @db = ::Honker::Database.new(@path, **opts)
    rescue => e
      @enabled = false
      @db = nil
      warn "[litestack] leadership disabled: #{e.class}: #{e.message}"
    end
  end
end
