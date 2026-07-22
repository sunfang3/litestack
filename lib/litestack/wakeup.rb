# frozen_string_literal: true

require_relative "wakeup/base"
require_relative "wakeup/polling"
require_relative "wakeup/honker"

module Litestack
  # Process-local wake layer for LiteJob (and optionally LiteCable).
  #
  # Honker answers "something changed in the SQLite file" (or a filtered
  # notification arrived). LiteQueue remains the source of truth for jobs.
  module Wakeup
    module_function

    # Build a wakeup backend from Litejobqueue-style options.
    #
    #   wakeup: :polling
    #   wakeup: :honker
    #   wakeup: { adapter: :honker, poll_interval_ms: 5, fallback_interval: 5 }
    def build(options = {})
      cfg = normalize_config(options)
      adapter = cfg[:adapter]

      case adapter
      when :honker, "honker"
        if Honker.available?(path: cfg[:path])
          Honker.new(**cfg.slice(
            :path, :poll_interval_ms, :fallback_interval, :channels,
            :filter_notifications, :extension_path, :watcher_backend
          ))
        else
          warn_honker_unavailable(cfg[:path])
          Polling.new(fallback_interval: cfg[:fallback_interval])
        end
      when :polling, "polling", nil
        Polling.new(fallback_interval: cfg[:fallback_interval])
      else
        raise ArgumentError, "unknown wakeup adapter: #{adapter.inspect}"
      end
    end

    def normalize_config(options)
      raw = options[:wakeup]
      base = {
        path: options[:path],
        adapter: :polling,
        poll_interval_ms: options[:watcher_poll_interval_ms] || 5,
        fallback_interval: options[:fallback_interval] || options[:wakeup_fallback_interval] || 5.0,
        channels: options[:wakeup_channels],
        filter_notifications: options.fetch(:wakeup_filter_notifications, false),
        extension_path: options[:honker_extension_path],
        watcher_backend: options[:watcher_backend]
      }

      case raw
      when Hash
        h = raw.transform_keys(&:to_sym)
        base.merge!(h)
        base[:adapter] = (h[:adapter] || h[:wakeup] || :honker).to_sym
      when Symbol, String
        base[:adapter] = raw.to_sym
      when nil
        # keep defaults
      else
        raise ArgumentError, "wakeup must be a Symbol, String, or Hash"
      end

      base[:poll_interval_ms] = base[:poll_interval_ms].to_i
      base[:fallback_interval] = base[:fallback_interval].to_f
      base
    end
    private_class_method :normalize_config

    def warn_honker_unavailable(path)
      reason =
        if path.to_s == ":memory:" || path.to_s.start_with?("file::memory:")
          "in-memory SQLite path cannot be watched"
        elsif !Honker.load_honker_gem!
          "honker gem not installed or incomplete"
        else
          "honker extension or path unavailable"
        end
      warn "[litestack] wakeup:honker unavailable (#{reason}); falling back to polling"
    end
    private_class_method :warn_honker_unavailable
  end
end
