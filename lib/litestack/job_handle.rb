# frozen_string_literal: true

module Litestack
  # Returned by Litejobqueue#push / Litejob.perform_*. Supports multiple
  # assignment for backward compatibility:
  #
  #   id, queue = MyJob.perform_async(...)
  #   handle = MyJob.perform_async(...)
  #   result = handle.wait(timeout: 30)
  class JobHandle
    attr_reader :id, :queue_name

    def initialize(jobqueue, id, queue_name)
      @jobqueue = jobqueue
      @id = id.to_s
      @queue_name = queue_name.to_s
    end

    # Block until the job stores a result (or +timeout+ seconds elapse).
    # Returns a Hash { status:, value:, error: } or nil on timeout / disabled store.
    def wait(timeout: nil)
      @jobqueue.wait_for_result(@id, timeout: timeout)
    end

    def result
      @jobqueue.job_result(@id)
    end

    def ready?
      !result.nil?
    end

    def successful?
      r = result
      r && r[:status].to_s == "ok"
    end

    # Multiple-assignment and index compatibility with historical [id, queue].
    def to_ary
      [@id, @queue_name]
    end

    alias_method :to_a, :to_ary

    def [](index)
      case index
      when 0 then @id
      when 1 then @queue_name
      end
    end

    def to_s
      @id
    end

    def inspect
      "#<#{self.class} id=#{@id.inspect} queue=#{@queue_name.inspect}>"
    end
  end
end
