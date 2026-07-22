# frozen_string_literal: true

module Litestack
  module Wakeup
    # Classic timeout-based wait. Workers still share one Waiter so a local
    # +signal+ after enqueue wakes everyone immediately (no multi-second backoff
    # when the producer is in-process).
    class Polling < Base
      def initialize(fallback_interval: 5.0)
        @fallback_interval = fallback_interval.to_f
        @fallback_interval = 0.001 if @fallback_interval <= 0
        @waiter = Litescheduler::Waiter.new
        @closed = false
      end

      def wait(timeout:)
        return false if @closed

        duration = timeout.nil? ? @fallback_interval : [timeout.to_f, @fallback_interval].min
        duration = 0 if duration.negative?
        @waiter.sleep(duration)
      end

      def signal
        @waiter.wake!
      end

      def close
        @closed = true
        @waiter.wake!
      end
    end
  end
end
