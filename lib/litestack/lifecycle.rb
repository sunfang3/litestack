# frozen_string_literal: true

require "oj"

module Litestack
  # Optional durable job lifecycle stream (Honker stream).
  #
  # Events: job.enqueued, job.started, job.succeeded, job.retried, job.dead, job.failed
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

      payload = fields.merge(
        event: event.to_s,
        at: Time.now.to_f,
        pid: Process.pid
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

    private

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
