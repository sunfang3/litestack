# frozen_string_literal: true

module Litestack
  module JobBackend
    # Thin adapter over Litequeue#push / #pop / #repush.
    # Jobs are deleted before perform (existing semantics).
    class Destructive
      def initialize(jobqueue)
        @jobqueue = jobqueue
      end

      def name
        :litequeue
      end

      def push(serialized_payload, delay, queue)
        @jobqueue.__send__(:_backend_push, serialized_payload, delay, queue)
      end

      def repush(id, serialized_payload, delay, queue)
        @jobqueue.__send__(:_backend_repush, id, serialized_payload, delay, queue)
      end

      def delete(id)
        @jobqueue.__send__(:_backend_delete, id)
      end

      # Returns [id, serialized_job] or nil.
      def claim(queue, limit = 1)
        @jobqueue.__send__(:_backend_pop, queue, limit)
      end

      # No-op: destructive pop already removed the row.
      def ack(_job_handle)
        true
      end

      # No claim lease — yield only.
      def with_heartbeat(_job_handle)
        yield
      end

      def retry(job_handle, serialized_payload, delay, queue)
        id = job_handle.is_a?(Array) ? job_handle[0] : job_handle
        repush(id, serialized_payload, delay, queue)
      end

      def next_fire_at(queue_names)
        @jobqueue.next_fire_at(queue_names)
      end

      def setup!
      end

      def close
      end

      def worker_id
        nil
      end
    end
  end
end
