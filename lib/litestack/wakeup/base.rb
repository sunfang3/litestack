# frozen_string_literal: true

module Litestack
  module Wakeup
    # Shared wait/signal surface used by LiteJob workers.
    #
    # +wait+ blocks until +signal+/+broadcast+ is called, the timeout elapses,
    # or the backend is closed. Implementations must be fork-safe when recreated
    # from Liteconnection#setup.
    class Base
      def wait(timeout:)
        raise NotImplementedError
      end

      # Wake local waiters (same process). Always safe after push/repush.
      def signal
        raise NotImplementedError
      end

      def broadcast
        signal
      end

      # Compat with Litescheduler::Waiter / Liteconnection#wake_workers!
      def wake!
        signal
      end

      def close
      end

      def adapter_name
        self.class.name.split("::").last.downcase.to_sym
      end
    end
  end
end
