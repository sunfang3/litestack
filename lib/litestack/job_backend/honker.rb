# frozen_string_literal: true

require "json"
require "securerandom"

module Litestack
  module JobBackend
    # At-least-once backend using Honker claim/ack/retry.
    #
    # Job payload format matches LiteJob (JSON with klass/params/retries/queue).
    # Queue names map 1:1 to Honker queue names. The special "_dead" queue is a
    # separate Honker queue for exhausted jobs.
    class Honker
      def self.available?(path: nil)
        return false if path && !Litestack::Wakeup::Honker.watchable_path?(path)

        Litestack::Wakeup::Honker.load_honker_gem!
      end

      def initialize(jobqueue, options = {})
        raise LoadError, "honker gem not available" unless self.class.available?(path: options[:path])

        @jobqueue = jobqueue
        @options = options
        @path = options[:path].to_s
        @visibility_timeout = (options[:visibility_timeout] || options[:visibility_timeout_s] || 300).to_i
        @visibility_timeout = 300 if @visibility_timeout <= 0
        @max_attempts = (options[:retries] || 5).to_i + 1 # Honker counts attempts including first
        # How often to extend a claim while perform runs. 0 disables heartbeat.
        @heartbeat_interval = (options[:heartbeat_interval] || options[:heartbeat_interval_s] || 60).to_f
        # Seconds to extend visibility on each beat (default = full visibility timeout).
        @heartbeat_extend = (options[:heartbeat_extend] || options[:heartbeat_extend_s] || @visibility_timeout).to_i
        @heartbeat_extend = @visibility_timeout if @heartbeat_extend <= 0
        @extension_path = options[:honker_extension_path]
        @watcher_backend = options[:watcher_backend]
        @worker_id = options[:worker_id] || default_worker_id
        @queues = {}
        @db = nil
        @sweep_thread = nil
        @closed = false
      end

      def name
        :honker
      end

      def worker_id
        @worker_id
      end

      def setup!
        opts = {}
        opts[:extension_path] = @extension_path if @extension_path
        opts[:watcher_backend] = @watcher_backend if @watcher_backend
        opts[:watcher_poll_interval_ms] = (@options[:watcher_poll_interval_ms] || 5).to_i
        @db = ::Honker::Database.new(@path, **opts)
        # Background reclaim of expired claims
        @sweep_thread = Thread.new { sweep_loop }
        @sweep_thread.name = "litestack-honker-sweep" if @sweep_thread.respond_to?(:name=)
      end

      def push(serialized_payload, delay, queue)
        q = honker_queue(queue || "default")
        delay_s = delay.to_f
        delay_s = 0 if delay_s.negative?
        # Honker's SQL binding rejects Ruby Float for delay — use whole seconds.
        # ceil so sub-second delays (e.g. 0.15) still run after at least 1s.
        delay_arg = if delay_s > 0
          [delay_s.ceil, 1].max
        end
        id = q.enqueue(
          parse_payload(serialized_payload),
          delay: delay_arg
        )
        @db.mark_updated
        [id.to_s, queue || "default"]
      end

      def repush(id, serialized_payload, delay, queue)
        # Cancel old id if still present, then enqueue fresh (Honker has no same-id repush).
        begin
          honker_queue(queue || "default").cancel(id.to_i)
        rescue
          nil
        end
        push(serialized_payload, delay, queue)
      end

      def delete(id)
        # Search known queues — cancel is global by job id in Honker.
        q = honker_queue("default")
        raw = q.get_job(id.to_i)
        payload = raw && raw["payload"]
        q.cancel(id.to_i)
        payload ? [payload.is_a?(String) ? payload : JSON.dump(payload)] : nil
      end

      # Returns a handle: { id:, serialized:, queue:, job: Honker::Job }
      def claim(queue, limit = 1)
        q = honker_queue(queue)
        jobs = q.claim_batch(@worker_id, limit)
        return nil if jobs.empty?

        if limit == 1
          job = jobs.first
          [job.id.to_s, dump_payload(job.payload), job]
        else
          jobs.map { |job| [job.id.to_s, dump_payload(job.payload), job] }
        end
      end

      def ack(job_handle)
        job = extract_honker_job(job_handle)
        return true unless job

        job.ack
      end

      # Run +block+ while periodically heartbeating the claim so long jobs are
      # not reclaimed when visibility_timeout elapses mid-perform.
      def with_heartbeat(job_handle)
        job = extract_honker_job(job_handle)
        return yield if job.nil? || !heartbeat_enabled?

        stop = false
        mutex = Mutex.new
        cv = ConditionVariable.new
        thr = Thread.new do
          Thread.current.report_on_exception = false
          mutex.synchronize do
            until stop
              cv.wait(mutex, @heartbeat_interval)
              break if stop

              begin
                ok = job.heartbeat(extend_s: @heartbeat_extend)
                break unless ok
              rescue
                break
              end
            end
          end
        end
        thr.name = "litejob-hb-#{job.id}" if thr.respond_to?(:name=)

        begin
          yield
        ensure
          mutex.synchronize do
            stop = true
            cv.signal
          end
          thr.join(2)
          thr.kill if thr.alive?
        end
      end

      def heartbeat_enabled?
        @heartbeat_interval.positive?
      end

      def retry(job_handle, serialized_payload, delay, queue)
        job = extract_honker_job(job_handle)
        # LiteJob keeps retry metadata inside the JSON payload (remaining
        # attempts, etc.). Honker's native retry requeues the *original*
        # payload, so we release the claim and enqueue the updated blob.
        if job
          released = begin
            job.ack
          rescue
            false
          end
          unless released
            begin
              job.retry(delay_s: 0, error: "litejob-requeue")
            rescue
              nil
            end
          end
        end
        push(serialized_payload, delay, queue)
      end

      def next_fire_at(queue_names)
        return nil unless @db

        names = Array(queue_names).map(&:to_s)
        return nil if names.empty?

        # Honker stores run_at; query live table for earliest pending run.
        placeholders = (["?"] * names.size).join(", ")
        sql = <<~SQL
          SELECT MIN(run_at) FROM _honker_live
          WHERE queue IN (#{placeholders})
            AND status = 'pending'
            AND run_at > unixepoch('subsec')
        SQL
        val = @db.db.get_first_value(sql, names)
        val&.to_f
      rescue SQLite3::Exception
        nil
      end

      def close
        @closed = true
        if @sweep_thread&.alive?
          @sweep_thread.join(1)
          @sweep_thread.kill if @sweep_thread.alive?
        end
        begin
          @db&.close
        rescue
          nil
        end
        @db = nil
      end

      private

      def default_worker_id
        "litejob-#{Process.pid}-#{SecureRandom.hex(4)}"
      end

      def honker_queue(name)
        key = name.to_s
        @queues[key] ||= @db.queue(
          key,
          visibility_timeout_s: @visibility_timeout,
          max_attempts: @max_attempts
        )
      end

      def parse_payload(serialized)
        return serialized if serialized.is_a?(Hash)

        JSON.parse(serialized)
      rescue JSON::ParserError
        {"_raw" => serialized.to_s}
      end

      def dump_payload(payload)
        return payload if payload.is_a?(String)
        return JSON.dump(payload) if payload

        "{}"
      end

      def extract_honker_job(job_handle)
        case job_handle
        when ::Honker::Job
          job_handle
        when Array
          job_handle[2] if job_handle[2].is_a?(::Honker::Job)
        when Hash
          job_handle[:job] || job_handle["job"]
        end
      end

      def sweep_loop
        while !@closed && @db
          begin
            @queues.each_value do |q|
              q.sweep_expired
            end
            # also sweep common queues even if not yet touched
            %w[default _dead].each do |name|
              honker_queue(name).sweep_expired
            end
          rescue
            nil
          end
          sleep 30
        end
      end
    end
  end
end
