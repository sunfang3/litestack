# frozen_string_literal: true

require_relative "job_backend/destructive"
require_relative "job_backend/honker"

module Litestack
  # Pluggable storage/execution backends for Litejobqueue.
  #
  # * Destructive — classic LiteQueue push/pop (at-most-once if process dies mid-job)
  # * Honker — claim/ack with visibility timeout (at-least-once)
  module JobBackend
    module_function

    def build(jobqueue, options = {})
      name = options[:backend] || options[:job_backend] || :litequeue
      case name.to_sym
      when :litequeue, :destructive, :default
        Destructive.new(jobqueue)
      when :honker
        unless Honker.available?(path: options[:path])
          raise LoadError,
            "backend: :honker requires the honker gem and a file-backed queue path " \
            "(got #{options[:path].inspect})"
        end
        Honker.new(jobqueue, options)
      else
        raise ArgumentError, "unknown job backend: #{name.inspect}"
      end
    end
  end
end
