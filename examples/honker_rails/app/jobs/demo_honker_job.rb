# frozen_string_literal: true

# Sample job for the Honker Rails example.
# Enqueue: DemoHonkerJob.perform_later("hello")
# With job_results: true the handle can wait for the return value.
base = defined?(ApplicationJob) ? ApplicationJob : ActiveJob::Base
class DemoHonkerJob < base
  queue_as :default

  def perform(message = "honker")
    Rails.logger.info("[DemoHonkerJob] #{message}") if defined?(Rails)
    {ok: true, message: message, at: Time.now.utc.iso8601}
  end
end
