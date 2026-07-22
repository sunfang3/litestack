# frozen_string_literal: true

require_relative "helper"

describe "LiteJob JobHandle results and lifecycle" do
  before do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
  end

  after do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
    Object.send(:remove_const, :ResultJob) if defined?(ResultJob)
    Object.send(:remove_const, :FailOnceJob) if defined?(FailOnceJob)
  end

  it "returns a JobHandle that supports multiple assignment" do
    with_tmp_db("handle") do |path|
      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 0,
        queues: [["default", 1]],
        job_results: true,
        leadership: false,
        lifecycle_stream: false
      )
      handle = q.push("Object", [], 0, "default")
      assert_instance_of Litestack::JobHandle, handle
      id, queue = handle
      assert_equal handle.id, id
      assert_equal "default", queue
      assert_equal handle.id, handle.to_s
    ensure
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "stores a result and unblocks wait" do
    with_tmp_db("result-wait") do |path|
      job_klass = Class.new do
        def perform(n)
          n * 2
        end
      end
      Object.const_set(:ResultJob, job_klass)

      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        job_results: true,
        leadership: false,
        lifecycle_stream: false,
        wakeup: :polling,
        sleep_intervals: [0.01],
        fallback_interval: 1
      )

      handle = q.push("ResultJob", [21], 0, "default")
      result = handle.wait(timeout: 3)
      refute_nil result
      assert_equal "ok", result[:status]
      assert_equal 42, result[:value]
      assert handle.successful?
    ensure
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "records dead status after retries exhausted" do
    with_tmp_db("result-dead") do |path|
      job_klass = Class.new do
        def perform
          raise "nope"
        end
      end
      Object.const_set(:FailOnceJob, job_klass)

      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        job_results: true,
        leadership: false,
        lifecycle_stream: false,
        dead_job_retention: 60,
        sleep_intervals: [0.01],
        fallback_interval: 1
      )

      handle = q.push("FailOnceJob", [], 0, "default")
      result = handle.wait(timeout: 3)
      refute_nil result
      assert_equal "dead", result[:status]
      assert_match(/nope/, result[:error].to_s)
    ensure
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "emits lifecycle stream events when enabled" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("lifecycle") do |path|
      job_klass = Class.new do
        def perform
          :done
        end
      end
      Object.const_set(:ResultJob, job_klass)

      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        lifecycle_stream: true,
        job_results: true,
        leadership: false,
        sleep_intervals: [0.01],
        fallback_interval: 1
      )

      handle = q.push("ResultJob", [], 0, "default")
      handle.wait(timeout: 3)

      life = q.instance_variable_get(:@lifecycle)
      assert life.enabled?
      events = life.read_since(0, 50)
      names = events.map do |e|
        p = e.respond_to?(:payload) ? e.payload : e
        p.is_a?(Hash) ? (p["event"] || p[:event]) : nil
      end
      assert_includes names, "job.enqueued"
      assert_includes names, "job.succeeded"
    ensure
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end
end

describe "LiteJob leadership GC" do
  it "builds leadership when honker path is available" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("lead-gc") do |path|
      Litejobqueue.reset_singleton!
      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        leadership: true,
        gc_sleep_interval: 3600,
        sleep_intervals: [0.05]
      )
      lead = q.instance_variable_get(:@gc_leadership)
      refute_nil lead
      assert lead.enabled?
    ensure
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end

  it "skips leadership for :memory: paths" do
    Litejobqueue.reset_singleton!
    q = Litejobqueue.jobqueue(
      path: ":memory:",
      logger: nil,
      workers: 0,
      leadership: true
    )
    assert_nil q.instance_variable_get(:@gc_leadership)
  ensure
    Litejobqueue.reset_singleton!
  end
end
