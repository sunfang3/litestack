# frozen_string_literal: true

require_relative "../../litestack/compatibility"
Litestack::Compatibility.assert_rails_supported!

require_relative "../../litestack/litejob"
require "active_support"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/array/access"
require "active_job"

module ActiveJob
  module QueueAdapters
    # == Litestack adapter for Active Job
    #
    #   Rails.application.config.active_job.queue_adapter = :litejob
    class LitejobAdapter < AbstractAdapter
      def initialize(options = {})
        @options = options || {}
        Job.get_jobqueue
      end

      def enqueue_after_transaction_commit?
        # Prefer the live jobqueue options (reflects database: primary / outbox).
        queue = begin
          Job.jobqueue
        rescue
          nil
        end
        if queue && queue.respond_to?(:options) && queue.options.key?(:enqueue_after_transaction_commit)
          return !!queue.options[:enqueue_after_transaction_commit]
        end
        !!Job.options[:enqueue_after_transaction_commit]
      end

      def stopping?
        queue = Job.jobqueue
        queue.respond_to?(:stopping?) && queue.stopping?
      end

      def enqueue(job) # :nodoc:
        queue_name = job.queue_name
        if stopping?
          # Persist for later process; do not start locally
          instrument_deferred(job)
        end
        provider_job_id = Job.perform_async_on_queue(queue_name, job.serialize)
        job.provider_job_id = provider_job_id if job.respond_to?(:provider_job_id=)
        provider_job_id
      end

      def enqueue_at(job, time) # :nodoc:
        time = time.from_now if time.respond_to?(:from_now)
        queue_name = job.queue_name
        if stopping?
          instrument_deferred(job)
        end
        provider_job_id = Job.perform_at_on_queue(queue_name, time, job.serialize)
        job.provider_job_id = provider_job_id if job.respond_to?(:provider_job_id=)
        provider_job_id
      end

      def shutdown
        Job.jobqueue&.stop
      end

      private

      def instrument_deferred(job)
        if defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.instrument(
            "litestack.litejob.deferred_during_shutdown",
            job_class: job.class.name,
            queue: job.queue_name
          )
        end
      end

      class Job # :nodoc:
        DEFAULT_OPTIONS = {
          config_path: "./config/litejob.yml",
          logger: nil, # Rails performs its logging already
          # Overridden to false automatically when database: primary / outbox: true
          enqueue_after_transaction_commit: true
        }

        # ensure litejob is not started unless the LitejobAdapter is initialized
        def self.defer_litejob_start? = true

        include ::Litejob

        def self.perform_async_on_queue(queue_name, *args)
          self.queue = queue_name
          perform_async(*args)
        ensure
          self.queue = nil
        end

        def self.perform_at_on_queue(queue_name, time, *args)
          self.queue = queue_name
          perform_at(time, *args)
        ensure
          self.queue = nil
        end

        def self.jobqueue
          get_jobqueue
        end

        def perform(job_data) = Base.execute job_data
      end
    end
  end
end
