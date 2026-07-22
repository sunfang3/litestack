# frozen_string_literal: true

require_relative "helper"
require "timeout"
require "litestack/litecable"

describe "Litecable honker transport" do
  it "falls back to polling for :memory: path" do
    cable = Litecable.new(path: ":memory:", transport: :honker, logger: nil, metrics: false)
    assert_equal :polling, cable.options[:transport]
    received = []
    cable.subscribe("chat", ->(msg) { received << msg })
    cable.broadcast("chat", "hi")
    assert_equal ["hi"], received
    cable.close
  end

  it "delivers cross-process messages via honker notify" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("cable-honker") do |path|
      a = Litecable.new(
        path: path,
        transport: :honker,
        logger: nil,
        metrics: false,
        expire_after: 30,
        watcher_poll_interval_ms: 5
      )
      b = Litecable.new(
        path: path,
        transport: :honker,
        logger: nil,
        metrics: false,
        expire_after: 30,
        watcher_poll_interval_ms: 5
      )

      received = Queue.new
      b.subscribe("room", ->(msg) { received << msg })

      # Give listeners time to attach
      sleep 0.1
      a.broadcast("room", {"text" => "hello"})

      msg = nil
      begin
        Timeout.timeout(3) { msg = received.pop }
      rescue Timeout::Error
        flunk "timed out waiting for honker cable message"
      end
      assert_equal({"text" => "hello"}, msg)
    ensure
      a&.close rescue nil
      b&.close rescue nil
    end
  end

  it "does not double-deliver to the publishing process" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("cable-local") do |path|
      cable = Litecable.new(
        path: path,
        transport: :honker,
        logger: nil,
        metrics: false,
        watcher_poll_interval_ms: 5
      )
      count = 0
      mutex = Mutex.new
      cable.subscribe("x", ->(_msg) { mutex.synchronize { count += 1 } })
      cable.broadcast("x", 1)
      sleep 0.3
      assert_equal 1, count
    ensure
      cable&.close rescue nil
    end
  end
end
