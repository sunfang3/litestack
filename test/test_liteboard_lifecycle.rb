# frozen_string_literal: true

require_relative "helper"
require "litestack/liteboard/liteboard"
require "litestack/lifecycle"
require "json"

describe "Liteboard lifecycle feed" do
  before do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
  end

  after do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
  end

  def rack_env(path = "/", query = "")
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "QUERY_STRING" => query,
      "rack.input" => StringIO.new(""),
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "9292"
    }
  end

  it "returns JSON lifecycle feed shape" do
    status, headers, body = Liteboard.app.call(rack_env("/topics/Litejob/lifecycle.json"))
    assert_equal 200, status
    assert_match(%r{application/json}, headers["content-type"] || headers["Content-Type"])
    data = JSON.parse(body.join)
    assert data.key?("enabled")
    assert data.key?("events")
    assert data["events"].is_a?(Array)
  end

  it "reports not watchable for :memory: path" do
    ENV["LITEBOARD_QUEUE_PATH"] = ":memory:"
    feed = Litestack::Lifecycle.read_recent(path: ":memory:")
    assert_equal false, feed[:enabled]
    assert_match(/watchable|not/i, feed[:reason].to_s)
  ensure
    ENV.delete("LITEBOARD_QUEUE_PATH")
  end

  it "Lifecycle.read_recent returns events written by litejob" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("life-board") do |path|
      job = Class.new do
        def perform
          :ok
        end
      end
      Object.const_set(:BoardLifeJob, job)

      q = Litejobqueue.jobqueue(
        path: path,
        logger: nil,
        workers: 1,
        queues: [["default", 1]],
        retries: 0,
        lifecycle_stream: true,
        leadership: false,
        job_results: true,
        sleep_intervals: [0.01],
        fallback_interval: 1
      )
      handle = q.push("BoardLifeJob", [], 0, "default")
      handle.wait(timeout: 3)

      feed = Litestack::Lifecycle.read_recent(path: path, limit: 20)
      assert feed[:enabled], feed[:reason].to_s
      names = feed[:events].map { |e| e[:event] }
      assert_includes names, "job.enqueued"
      assert_includes names, "job.succeeded"

      ENV["LITEBOARD_QUEUE_PATH"] = path
      status, _headers, body = Liteboard.app.call(rack_env("/topics/Litejob/lifecycle.json"))
      assert_equal 200, status
      data = JSON.parse(body.join)
      assert_equal true, data["enabled"]
      assert data["events"].any? { |e| e["event"] == "job.enqueued" }

      status2, _h2, body2 = Liteboard.app.call(rack_env("/topics/Litejob"))
      assert_equal 200, status2
      html = body2.join
      assert_match(/Job lifecycle stream/i, html)
      assert_match(/job\.enqueued|job\.succeeded/, html)
    ensure
      ENV.delete("LITEBOARD_QUEUE_PATH")
      Object.send(:remove_const, :BoardLifeJob) if defined?(BoardLifeJob)
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
    end
  end
end

describe "Leadership exclusivity" do
  it "only one holder runs with_lock work at a time" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("lead-excl") do |path|
      a = Litestack::Leadership.new(path: path, name: "litestack:test:lock", ttl_s: 10)
      b = Litestack::Leadership.new(path: path, name: "litestack:test:lock", ttl_s: 10)
      assert a.enabled?
      assert b.enabled?

      ran_a = false
      ran_b = false
      lock_a = a.try_acquire
      refute_nil lock_a
      # B should fail while A holds
      lock_b = b.try_acquire
      assert_nil lock_b

      a.with_lock { ran_a = true } # acquires again after release? try_acquire already held
      # release explicit handle
      lock_a.release
      ok = b.with_lock { ran_b = true }
      assert ok
      assert ran_b
    ensure
      a&.close
      b&.close
    end
  end
end
