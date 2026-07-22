# frozen_string_literal: true

module Litestack
  module Wakeup
    # Honker-backed wakeup: one native watcher per process fans out to all
    # local LiteJob workers via Litescheduler::Waiter.
    #
    # Without +filter_notifications+, any commit on the queue database file
    # wakes workers (data_version). With filtering, only rows in
    # +_honker_notifications+ matching +channels+ (or the litequeue: prefix)
    # wake workers — avoiding pop/GC thrash.
    class Honker < Base
      CHANNEL_PREFIX = "litequeue:"

      def self.available?(path: nil)
        return false if path && !watchable_path?(path)

        load_honker_gem!
      end

      # Bundler may pre-load honker/version.rb (empty module shell). Always require
      # the full gem and verify Database is present.
      def self.load_honker_gem!
        require "honker"
        return true if defined?(::Honker::Database)

        false
      rescue LoadError
        false
      end

      def self.watchable_path?(path)
        s = path.to_s
        return false if s.empty? || s == ":memory:"
        return false if s.start_with?("file::memory:")
        true
      end

      def initialize(path:, poll_interval_ms: 5, fallback_interval: 5.0,
        channels: nil, filter_notifications: false,
        extension_path: nil, watcher_backend: nil)
        raise ArgumentError, "path required for honker wakeup" unless self.class.watchable_path?(path)
        raise LoadError, "honker gem not available" unless self.class.load_honker_gem!

        @path = path.to_s
        @poll_interval_ms = [poll_interval_ms.to_i, 1].max
        @fallback_interval = fallback_interval.to_f
        @fallback_interval = 5.0 if @fallback_interval <= 0
        @filter_notifications = !!filter_notifications
        @channels = Array(channels).map(&:to_s)
        @extension_path = extension_path
        @watcher_backend = watcher_backend
        @waiter = Litescheduler::Waiter.new
        @mutex = Mutex.new
        @closed = false
        @db = nil
        @thread = nil
        @last_notification_id = 0

        open!
      end

      def wait(timeout:)
        return false if @closed

        duration = if timeout.nil?
          @fallback_interval
        else
          [timeout.to_f, @fallback_interval].min
        end
        duration = 0 if duration.negative?
        @waiter.sleep(duration)
      end

      def signal
        @waiter.wake!
      end

      def close
        thread = nil
        db = nil
        @mutex.synchronize do
          return if @closed

          @closed = true
          thread = @thread
          db = @db
          @thread = nil
          @db = nil
        end
        @waiter.wake!
        if thread&.alive?
          # Unblock native wait so the hub can shut down.
          begin
            db&.mark_updated
          rescue
            nil
          end
          thread.join(2)
          thread.kill if thread.alive?
        end
        begin
          db&.close
        rescue
          nil
        end
      end

      private

      def open!
        opts = {watcher_poll_interval_ms: @poll_interval_ms}
        opts[:extension_path] = @extension_path if @extension_path
        opts[:watcher_backend] = @watcher_backend if @watcher_backend
        @db = ::Honker::Database.new(@path, **opts)
        if @filter_notifications
          @last_notification_id = max_notification_id
        end
        @thread = Thread.new { watch_loop }
        @thread.name = "litestack-honker-wakeup" if @thread.respond_to?(:name=)
      end

      def watch_loop
        while !@closed && (db = @db)
          begin
            if @filter_notifications
              if pending_notifications?
                signal
                # brief pause so workers drain before we re-check
                db.wait_for_update(0.05) unless @closed
              else
                db.wait_for_update(@fallback_interval) unless @closed
              end
            else
              # Any commit (including remote enqueue) wakes us.
              woke = db.wait_for_update(@fallback_interval)
              signal if woke && !@closed
            end
          rescue ::Honker::Error, ArgumentError, IOError, SQLite3::Exception
            break if @closed
            sleep 0.05
          rescue => e
            break if @closed
            warn "[litestack] honker wakeup error: #{e.class}: #{e.message}"
            sleep 0.1
          end
        end
      end

      def max_notification_id
        row = @db.db.get_first_value("SELECT COALESCE(MAX(id), 0) FROM _honker_notifications")
        row.to_i
      rescue SQLite3::Exception
        0
      end

      def pending_notifications?
        sql, binds = notification_query
        rows = @db.db.execute(sql, binds)
        return false if rows.empty?

        @last_notification_id = rows.last[0].to_i
        true
      rescue SQLite3::Exception
        false
      end

      def notification_query
        if @channels.empty?
          [
            "SELECT id FROM _honker_notifications WHERE id > ? AND channel LIKE ? ORDER BY id",
            [@last_notification_id, "#{CHANNEL_PREFIX}%"]
          ]
        else
          placeholders = (["?"] * @channels.size).join(", ")
          [
            "SELECT id FROM _honker_notifications WHERE id > ? AND channel IN (#{placeholders}) ORDER BY id",
            [@last_notification_id, *@channels]
          ]
        end
      end
    end
  end
end
