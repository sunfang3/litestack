# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/litestack/litecache"

describe "Litecache L1" do
  def build(l1: true, **opts)
    ::Litecache.new({
      path: ":memory:",
      sleep_interval: 3600,
      logger: nil,
      l1: l1,
      l1_max_entries: 100,
      l1_max_value_bytes: 1024,
      l1_ttl: 0
    }.merge(opts))
  end

  it "is disabled by default" do
    c = build(l1: false)
    refute c.l1_enabled?
    assert_equal false, c.l1_stats[:enabled]
    c.set("a", "1")
    assert_equal "1", c.get("a")
    assert_equal 0, c.l1_stats[:hits]
  ensure
    c&.close
  end

  it "serves hits from L1 after set" do
    c = build
    assert c.l1_enabled?
    c.set("a", "hello")
    # First get after set is L1 hit (set populated L1)
    assert_equal "hello", c.get("a")
    assert_equal "hello", c.get("a")
    stats = c.l1_stats
    assert stats[:hits] >= 2
    assert_operator stats[:hit_rate], :>, 0.0
  ensure
    c&.close
  end

  it "fills L1 on L2 get miss path" do
    c = build
    # Write via raw path: set fills L1; clear only L1 by building second view...
    # Force L2-only write by using set then clearing L1 stats via internal store.
    c.set("k", "v")
    c.instance_variable_get(:@l1).clear
    c.instance_variable_get(:@l1).reset_stats!
    assert_equal "v", c.get("k") # L2 fill
    assert_equal 0, c.l1_stats[:hits]
    assert_equal 1, c.l1_stats[:misses]
    assert_equal "v", c.get("k") # L1 hit
    assert_equal 1, c.l1_stats[:hits]
  ensure
    c&.close
  end

  it "delete removes L1 and L2" do
    c = build
    c.set("x", "1")
    assert c.delete("x")
    assert_nil c.get("x")
  ensure
    c&.close
  end

  it "clear empties L1" do
    c = build
    c.set("x", "1")
    c.clear
    assert_nil c.get("x")
    assert_equal 0, c.l1_stats[:entries]
  ensure
    c&.close
  end

  it "skips L1 for oversized values" do
    c = build(l1_max_value_bytes: 8)
    c.set("big", "0123456789abcdef") # 16 bytes
    assert_equal 0, c.l1_stats[:entries]
    assert_equal "0123456789abcdef", c.get("big") # L2
    # still not stored (too large)
    assert_equal 0, c.l1_stats[:entries]
  ensure
    c&.close
  end

  it "evicts LRU when over max_entries" do
    c = build(l1_max_entries: 3)
    c.set("a", "1")
    c.set("b", "2")
    c.set("c", "3")
    c.get("a") # touch a → most recent
    c.set("d", "4") # should evict least-recent among b/c
    assert_equal 3, c.l1_stats[:entries]
    hit, val = c.instance_variable_get(:@l1).fetch("a")
    assert hit
    assert_equal "1", val
    # b or c evicted from L1 but still readable from L2
    assert_equal "2", c.get("b")
    assert_equal "4", c.get("d")
  ensure
    c&.close
  end

  it "respects soft l1_ttl" do
    c = build(l1_ttl: 0.15)
    c.set("t", "v")
    assert_equal "v", c.get("t")
    sleep 0.2
    # L1 expired → L2 still has it
    assert_equal "v", c.get("t")
  ensure
    c&.close
  end

  it "does not cache increment in L1" do
    c = build
    c.set("n", 1)
    c.increment("n", 2)
    # L1 dropped; get loads 3 from L2
    assert_equal 3, c.get("n")
  ensure
    c&.close
  end

  it "get_multi uses L1 then L2" do
    c = build
    c.set("a", "1")
    c.set("b", "2")
    c.instance_variable_get(:@l1).delete("b")
    rs = c.get_multi("a", "b", "c")
    assert_equal({"a" => "1", "b" => "2"}, rs)
  ensure
    c&.close
  end

  it "set_unless_exists only fills L1 on insert" do
    c = build
    assert c.set_unless_exists("u", "one")
    refute c.set_unless_exists("u", "two")
    assert_equal "one", c.get("u")
  ensure
    c&.close
  end
end
