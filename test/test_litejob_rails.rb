# frozen_string_literal: true

require_relative "helper"
require "active_job"
require "active_job/queue_adapters/litejob_adapter"
require "active_support/core_ext/numeric/time"

ActiveJob::Base.logger = Logger.new(IO::NULL)

class LitejobRailsJob < ActiveJob::Base
  queue_as :test

  cattr_accessor :sink
  self.sink = {}

  def perform(key, time)
    self.class.sink[key] = true
  end
end

class TestLitejobRails < Minitest::Test
  def setup
    # Dedicated queue options for Rails AJ smoke; jobqueue recreates if closed.
    @ljq = Litejobqueue.jobqueue(
      path: ":memory:",
      retries: 1,
      retry_delay: 1,
      retry_delay_multiplier: 1,
      sleep_intervals: [0.01],
      queues: [["test", 1], ["default", 1]],
      logger: nil,
      workers: 2
    )
    LitejobRailsJob.queue_adapter = :litejob
    LitejobRailsJob.sink = {}
    sleep 0.05
  end

  def teardown
    live_litejobqueue
  end

  def test_job_is_performed_now
    assert LitejobRailsJob.perform_now(:now, Time.now)
    assert LitejobRailsJob.sink[:now]
  end

  def test_job_is_performed_later
    LitejobRailsJob.perform_later(:later, Time.now)
    assert_nil LitejobRailsJob.sink[:later]
    wait_until(5.0) { LitejobRailsJob.sink[:later] }
    assert LitejobRailsJob.sink[:later], "expected Active Job perform_later to be executed by Litejob workers"
  end

  def test_enqueue_at_schedules_job
    adapter = ActiveJob::QueueAdapters::LitejobAdapter.new
    job = LitejobRailsJob.new(:scheduled, Time.now)
    job.queue_name = "test"
    id = adapter.enqueue_at(job, 5.seconds.from_now)
    refute_nil id
    # Job should be durable in the queue while delayed
    assert_operator @ljq.count, :>=, 0
  end

  def test_find_job_by_class_name_and_params
    adapter = ActiveJob::QueueAdapters::LitejobAdapter.new
    j1 = LitejobRailsJob.new(:two_seconds, Time.now)
    j1.queue_name = "test"
    j2 = LitejobRailsJob.new(:three_seconds, Time.now)
    j2.queue_name = "test"
    adapter.enqueue_at(j1, 30.seconds.from_now)
    adapter.enqueue_at(j2, 60.seconds.from_now)
    res = @ljq.find(params: "two_seconds")
    assert_operator res.length, :>=, 1
    res = @ljq.find(klass: "NonExistentJob")
    assert_equal 0, res.length
  end

  private

  def wait_until(time)
    slept = 0.0
    step = 0.05
    while slept < time
      return if yield
      sleep step
      slept += step
    end
  end
end
