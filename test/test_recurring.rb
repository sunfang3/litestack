# frozen_string_literal: true

require_relative "helper"
require "yaml"
require "fileutils"

describe "Litestack::Recurring::Cron" do
  it "matches a simple cron expression" do
    c = Litestack::Recurring::Cron.parse("0 12 * * *")
    t = Time.new(2026, 7, 22, 12, 0, 0)
    assert c.matches?(t)
    refute c.matches?(Time.new(2026, 7, 22, 12, 1, 0))
  end

  it "supports step values" do
    c = Litestack::Recurring::Cron.parse("*/15 * * * *")
    assert c.matches?(Time.new(2026, 1, 1, 0, 0, 0))
    assert c.matches?(Time.new(2026, 1, 1, 0, 15, 0))
    refute c.matches?(Time.new(2026, 1, 1, 0, 7, 0))
  end

  it "next_after advances at least one minute" do
    c = Litestack::Recurring::Cron.parse("0 * * * *")
    from = Time.new(2026, 1, 1, 10, 30, 0)
    nxt = c.next_after(from)
    assert nxt
    assert nxt > from
    assert_equal 0, nxt.min
  end
end

describe "Litestack::Recurring::Definition" do
  it "parses every N minutes" do
    d = Litestack::Recurring::Definition.from_hash("ping", {
      "class" => "PingJob",
      "schedule" => "every 5 minutes"
    })
    assert d.interval?
    assert d.due?(Time.now, nil, nil)
    refute d.due?(Time.now, Time.now.to_f - 60, "x")
    assert d.due?(Time.now, Time.now.to_f - 400, "x")
  end

  it "parses cron schedule" do
    d = Litestack::Recurring::Definition.from_hash("hourly", {
      "class" => "HourlyJob",
      "schedule" => "0 * * * *"
    })
    refute d.interval?
    now = Time.new(2026, 3, 1, 8, 0, 0)
    assert d.due?(now, nil, nil)
    key = d.slot_key(now)
    refute d.due?(now, now.to_f, key)
  end
end

describe "Litestack::Recurring::Scheduler" do
  before do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
  end

  after do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
  end

  it "enqueues an interval job via tick!" do
    with_tmp_db("recurring-int") do |path|
      job = Class.new do
        def perform
          Performance.performed!
        end
      end
      Object.const_set(:RecurringPingJob, job)

      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        sleep_intervals: [0.01],
        fallback_interval: 0.5,
        leadership: false,
        lifecycle_stream: false,
        job_results: false,
        recurring_tick: 1,
        recurring: {
          "ping" => {
            "class" => "RecurringPingJob",
            "every" => 1,
            "queue" => "default"
          }
        }
      )

      # Force an immediate tick
      sched = q.instance_variable_get(:@recurring_scheduler)
      # Scheduler runs in background; also call tick if available on queue
      if sched.nil?
        # Worker may not have started scheduler yet
        sleep 0.2
        sched = q.instance_variable_get(:@recurring_scheduler)
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      loop do
        break if Performance.performances.to_i >= 1
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "recurring job never ran (scheduler=#{sched.inspect})"
        end
        sleep 0.05
      end
      assert Performance.performances >= 1
      q.stop
    ensure
      Object.send(:remove_const, :RecurringPingJob) if defined?(RecurringPingJob)
    end
  end

  it "does not double-enqueue the same interval slot" do
    with_tmp_db("recurring-cron") do |path|
      job = Class.new do
        def perform
          Performance.performed!
        end
      end
      Object.const_set(:RecurringCronJob, job)

      now = Time.now
      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 0,
        queues: [["default", 1]],
        retries: 0,
        leadership: false,
        lifecycle_stream: false,
        job_results: false,
        recurring_path: "/nonexistent-recurring.yml",
        recurring: {
          "once" => {"class" => "RecurringCronJob", "every" => 3600}
        }
      )

      sched = Litestack::Recurring::Scheduler.new(q, q.options.merge(
        recurring: {"once" => {"class" => "RecurringCronJob", "every" => 3600}},
        recurring_path: "/nonexistent-recurring.yml"
      ))
      n1 = sched.tick!(now)
      n2 = sched.tick!(now)
      assert_equal 1, n1
      assert_equal 0, n2

      Litejobqueue.reset_singleton!
      q2 = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        sleep_intervals: [0.01],
        leadership: false,
        lifecycle_stream: false,
        job_results: false,
        recurring: nil,
        recurring_path: "/nonexistent-recurring.yml"
      )
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep 0.05 while Performance.performances.to_i < 1 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      assert_equal 1, Performance.performances
      sched.close
      q2.stop
    ensure
      Object.send(:remove_const, :RecurringCronJob) if defined?(RecurringCronJob)
    end
  end
end
