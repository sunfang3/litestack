# frozen_string_literal: true

require "oj"

module Litestack
  # Optional durable job lifecycle stream (Honker stream).
  #
  # Writer (Litejobqueue when lifecycle_stream: true):
  #   Events: job.enqueued, job.started, job.succeeded, job.retried, job.dead
  #
  # Reader (Liteboard / tooling):
  #   Litestack::Lifecycle.read_recent(path: queue_db_path, limit: 50)
  class Lifecycle
    DEFAULT_TOPIC = "litestack:litejob:events"

    def initialize(options = {})
      @options = options
      @topic = (options[:lifecycle_stream_topic] || DEFAULT_TOPIC).to_s
      @db = nil
      @stream = nil
      @enabled = false
      setup! if options[:lifecycle_stream]
    end

    def enabled?
      @enabled
    end

    def emit(event, **fields)
      return false unless @enabled && @stream

      payload = stringify_keys(fields).merge(
        "event" => event.to_s,
        "at" => Time.now.to_f,
        "pid" => Process.pid
      )
      @stream.publish(payload)
      @db.mark_updated
      true
    rescue => e
      warn "[litejob] lifecycle emit failed: #{e.class}: #{e.message}"
      false
    end

    def read_since(offset, limit = 100)
      return [] unless @enabled && @stream

      @stream.read_since(offset, limit)
    end

    def close
      begin
        @db&.close
      rescue
        nil
      end
      @db = nil
      @stream = nil
      @enabled = false
    end

    # Read recent events from a queue database path without a long-lived handle.
    # Returns a Hash suitable for JSON / Liteboard:
    #   { enabled:, topic:, events: [ {offset, event, job_id, queue, klass, at, ...} ], reason?: }
    def self.read_recent(path:, topic: DEFAULT_TOPIC, limit: 50, extension_path: nil, watcher_poll_interval_ms: 5)
      path = path.to_s
      topic = topic.to_s
      limit = [[limit.to_i, 1].max, 500].min

      unless path != "" && path != ":memory:" && Litestack::Wakeup::Honker.watchable_path?(path)
        return {enabled: false, topic: topic, events: [], reason: "queue path not watchable"}
      end
      unless Litestack::Wakeup::Honker.load_honker_gem!
        return {enabled: false, topic: topic, events: [], reason: "honker not available"}
      end

      opts = {watcher_poll_interval_ms: watcher_poll_interval_ms.to_i}
      opts[:extension_path] = extension_path if extension_path
      db = ::Honker::Database.new(path, **opts)
      stream = db.stream(topic)
      # Fetch a window from the start of the stream; take the newest N.
      # (Honker read_since is forward-only; board volumes are modest.)
      batch = stream.read_since(0, [limit * 20, 1000].max)
      recent = batch.last(limit)
      events = recent.map { |ev| event_to_hash(ev) }
      {
        enabled: true,
        topic: topic,
        events: events,
        count: events.size,
        max_offset: events.empty? ? 0 : events.last[:offset]
      }
    rescue => e
      {enabled: false, topic: topic, events: [], reason: "#{e.class}: #{e.message}"}
    ensure
      begin
        db&.close
      rescue
        nil
      end
    end

    def self.event_to_hash(ev)
      payload = ev.respond_to?(:payload) ? ev.payload : {}
      payload = {} unless payload.is_a?(Hash)
      # Normalize string/symbol keys
      p = {}
      payload.each { |k, v| p[k.to_s] = v }
      {
        offset: ev.respond_to?(:offset) ? ev.offset : nil,
        event: p["event"],
        job_id: p["job_id"],
        queue: p["queue"],
        klass: p["klass"],
        at: p["at"],
        pid: p["pid"],
        error: p["error"],
        delay: p["delay"],
        requeue: p["requeue"],
        raw: p
      }
    end

    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    private

    def stringify_keys(hash)
      self.class.stringify_keys(hash)
    end

    def setup!
      path = @options[:path].to_s
      return unless Litestack::Wakeup::Honker.available?(path: path)
      return unless Litestack::Wakeup::Honker.load_honker_gem!

      opts = {watcher_poll_interval_ms: (@options[:watcher_poll_interval_ms] || 5).to_i}
      opts[:extension_path] = @options[:honker_extension_path] if @options[:honker_extension_path]
      @db = ::Honker::Database.new(path, **opts)
      @stream = @db.stream(@topic)
      @enabled = true
    rescue => e
      @enabled = false
      warn "[litejob] lifecycle stream disabled: #{e.class}: #{e.message}"
    end
  end
end
