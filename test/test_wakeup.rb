# frozen_string_literal: true

require_relative "helper"
require "litestack/wakeup"

describe Litestack::Wakeup do
  it "builds a polling backend by default" do
    w = Litestack::Wakeup.build(path: ":memory:")
    assert_instance_of Litestack::Wakeup::Polling, w
    assert_equal :polling, w.adapter_name
    w.close
  end

  it "builds polling when adapter is explicit" do
    w = Litestack::Wakeup.build(path: ":memory:", wakeup: :polling)
    assert_instance_of Litestack::Wakeup::Polling, w
    w.close
  end

  it "falls back to polling for :memory: with honker adapter" do
    w = Litestack::Wakeup.build(path: ":memory:", wakeup: :honker)
    assert_instance_of Litestack::Wakeup::Polling, w
    w.close
  end

  it "wakes a waiting thread before timeout on signal" do
    w = Litestack::Wakeup::Polling.new(fallback_interval: 5)
    finished = Queue.new
    t = Thread.new do
      w.wait(timeout: 5)
      finished << true
    end
    sleep 0.05
    w.signal
    assert finished.pop
    t.join(1)
    w.close
  end

  it "honker adapter watches a file-backed db when gem is available" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("wakeup") do |path|
      # Bootstrap schema with a real queue file
      q = Litequeue.new(path: path, logger: nil)
      q.push("seed", 0, "default")

      w = Litestack::Wakeup.build(
        path: path,
        wakeup: {adapter: :honker, poll_interval_ms: 5, fallback_interval: 2}
      )
      assert_instance_of Litestack::Wakeup::Honker, w

      finished = Queue.new
      t = Thread.new do
        w.wait(timeout: 3)
        finished << true
      end
      sleep 0.05
      # External commit should wake the watcher
      q2 = Litequeue.new(path: path, logger: nil)
      q2.push("hello", 0, "default")

      assert_equal true, finished.pop
      t.join(1)
      w.close
      q.close
      q2.close
    end
  end
end

describe "Litejobqueue with wakeup" do
  before do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
  end

  after do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
  end

  it "processes an immediate job with polling wakeup" do
    with_tmp_db("job-poll") do |path|
      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        wakeup: :polling,
        sleep_intervals: [0.01, 0.05],
        fallback_interval: 1
      )

      class << self
        # noop
      end
      job_klass = Class.new do
        def perform
          Performance.performed!
        end
      end
      Object.const_set(:WakeupPollJob, job_klass)

      q.push("WakeupPollJob", [], 0, "default")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      while Performance.performances < 1 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.02
      end
      assert_equal 1, Performance.performances
    ensure
      Object.send(:remove_const, :WakeupPollJob) if defined?(WakeupPollJob)
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "processes an immediate job with honker wakeup" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("job-honker") do |path|
      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
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
      Object.const_set(:WakeupHonkerJob, job_klass)

      # Let workers go idle first
      sleep 0.1
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      q.push("WakeupHonkerJob", [], 0, "default")
      deadline = t0 + 3
      while Performance.performances < 1 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.01
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      assert_equal 1, Performance.performances
      # Should be well under the old 2s max idle sleep
      assert_operator elapsed, :<, 1.5
    ensure
      Object.send(:remove_const, :WakeupHonkerJob) if defined?(WakeupHonkerJob)
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "fires delayed jobs via deadline-aware wait" do
    with_tmp_db("job-delay") do |path|
      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        wakeup: :polling,
        sleep_intervals: [0.05],
        fallback_interval: 1
      )

      job_klass = Class.new do
        def perform
          Performance.performed!
        end
      end
      Object.const_set(:WakeupDelayJob, job_klass)

      q.push("WakeupDelayJob", [], 0.25, "default")
      # Not runnable yet
      sleep 0.05
      assert_equal 0, Performance.performances
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      while Performance.performances < 1 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.05
      end
      assert_equal 1, Performance.performances
    ensure
      Object.send(:remove_const, :WakeupDelayJob) if defined?(WakeupDelayJob)
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end
end
