# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/litestack/litecache"

describe "Litecache invalidate modes" do
  it "invalidate:ttl forces l1 and a positive soft TTL" do
    c = ::Litecache.new(
      path: ":memory:",
      sleep_interval: 3600,
      logger: nil,
      invalidate: :ttl,
      l1_ttl: 0,
      l1_ttl_default: 0.2
    )
    assert c.l1_enabled?
    assert_equal :ttl, c.invalidate_mode
    assert_operator c.options[:l1_ttl].to_f, :>, 0
    assert_equal "ttl", c.l1_stats[:invalidate_mode]

    c.set("k", "v")
    assert_equal "v", c.get("k")
    sleep 0.25
    # Soft TTL expired in L1; L2 still serves
    assert_equal "v", c.get("k")
  ensure
    c&.close
  end

  it "invalidate:honker falls back to ttl on :memory: path" do
    c = ::Litecache.new(
      path: ":memory:",
      sleep_interval: 3600,
      logger: nil,
      invalidate: :honker
    )
    assert c.l1_enabled?
    # memory path cannot host honker watcher
    assert_equal :ttl, c.invalidate_mode
  ensure
    c&.close
  end

  it "invalidate:honker drops peer L1 after set" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("cache-inv") do |path|
      a = ::Litecache.new(
        path: path,
        sleep_interval: 3600,
        logger: nil,
        l1: true,
        invalidate: :honker,
        l1_ttl: 60, # long TTL so only notify causes drop
        watcher_poll_interval_ms: 5
      )
      b = ::Litecache.new(
        path: path,
        sleep_interval: 3600,
        logger: nil,
        l1: true,
        invalidate: :honker,
        l1_ttl: 60,
        watcher_poll_interval_ms: 5
      )

      assert a.l1_stats[:honker]
      assert b.l1_stats[:honker]

      a.set("x", "one")
      # B loads into L1
      assert_equal "one", b.get("x")
      hit, = b.instance_variable_get(:@l1).fetch("x")
      assert hit

      a.set("x", "two")
      # Wait for invalidation
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        hit, = b.instance_variable_get(:@l1).fetch("x")
        break unless hit
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
      hit, = b.instance_variable_get(:@l1).fetch("x")
      refute hit, "peer L1 should have been dropped by honker notify"

      assert_equal "two", b.get("x")
    ensure
      a&.close
      b&.close
    end
  end

  it "invalidate:honker clear flushes peer L1" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.available?

    with_tmp_db("cache-clr") do |path|
      a = ::Litecache.new(path: path, sleep_interval: 3600, logger: nil, invalidate: :honker, l1_ttl: 60)
      b = ::Litecache.new(path: path, sleep_interval: 3600, logger: nil, invalidate: :honker, l1_ttl: 60)
      a.set("a", "1")
      a.set("b", "2")
      assert_equal "1", b.get("a")
      assert_equal "2", b.get("b")
      a.clear
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        break if b.l1_stats[:entries].to_i == 0
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
      assert_equal 0, b.l1_stats[:entries]
      assert_nil b.get("a")
    ensure
      a&.close
      b&.close
    end
  end
end
