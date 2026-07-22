# frozen_string_literal: true

require_relative "helper"

describe "Litejobqueue honker backend" do
  before do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
  end

  after do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
  end

  it "is unavailable for :memory: paths" do
    assert_raises(LoadError) do
      Litejobqueue.jobqueue(
        path: ":memory:",
        backend: :honker,
        logger: nil,
        workers: 0
      )
    end
  end

  it "claim/ack executes a job at least once" do
    skip "honker gem not available" unless Litestack::JobBackend::Honker.available?

    with_tmp_db("honker-backend") do |path|
      q = Litejobqueue.jobqueue(
        path: path,
        backend: :honker,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 1,
        retry_delay: 1,
        retry_delay_multiplier: 1,
        visibility_timeout: 60,
        wakeup: :honker,
        watcher_poll_interval_ms: 5,
        fallback_interval: 2,
        sleep_intervals: [0.01]
      )

      job_klass = Class.new do
        def perform
          Performance.performed!
        end
      end
      Object.const_set(:HonkerBackendJob, job_klass)

      q.push("HonkerBackendJob", [], 0, "default")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while Performance.performances < 1 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.02
      end
      assert_equal 1, Performance.performances
    ensure
      Object.send(:remove_const, :HonkerBackendJob) if defined?(HonkerBackendJob)
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "retries a failing job" do
    skip "honker gem not available" unless Litestack::JobBackend::Honker.available?

    with_tmp_db("honker-retry") do |path|
      q = Litejobqueue.jobqueue(
        path: path,
        backend: :honker,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 2,
        retry_delay: 1,
        retry_delay_multiplier: 1,
        visibility_timeout: 60,
        wakeup: :honker,
        watcher_poll_interval_ms: 5,
        fallback_interval: 2
      )

      job_klass = Class.new do
        def perform
          Performance.performed!
          raise "boom" if Performance.performances < 2
        end
      end
      Object.const_set(:HonkerRetryJob, job_klass)

      q.push("HonkerRetryJob", [], 0, "default")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
      while Performance.performances < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.05
      end
      assert_operator Performance.performances, :>=, 2
    ensure
      Object.send(:remove_const, :HonkerRetryJob) if defined?(HonkerRetryJob)
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "heartbeats so a long job is not reclaimed mid-perform" do
    skip "honker gem not available" unless Litestack::JobBackend::Honker.available?

    with_tmp_db("honker-hb") do |path|
      Performance.reset!
      q = Litejobqueue.jobqueue(
        path: path,
        backend: :honker,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        visibility_timeout: 2,
        heartbeat_interval: 0.5,
        heartbeat_extend: 3,
        wakeup: :honker,
        watcher_poll_interval_ms: 5,
        fallback_interval: 1,
        sleep_intervals: [0.05],
        leadership: false,
        lifecycle_stream: false
      )

      job_klass = Class.new do
        def perform
          Performance.performed!
          # Longer than visibility_timeout without heartbeat would lose the claim
          # and allow a second worker to re-run (or duplicate after sweep).
          sleep 3.2
          Performance.processed!(:done)
        end
      end
      Object.const_set(:HonkerHeartbeatJob, job_klass)

      q.push("HonkerHeartbeatJob", [], 0, "default")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
      while Performance.processed_items.nil? || Performance.processed_items.empty?
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
      assert_equal 1, Performance.performances, "job should run once (not reclaimed)"
      assert_equal [:done], Performance.processed_items
    ensure
      Object.send(:remove_const, :HonkerHeartbeatJob) if defined?(HonkerHeartbeatJob)
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end
end
