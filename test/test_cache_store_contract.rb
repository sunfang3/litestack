# frozen_string_literal: true

require_relative "helper"
require "active_support"
require "active_support/cache"
require "active_support/cache/litecache"

class TestCacheStoreContract < Minitest::Test
  def setup
    @before_format = ActiveSupport::Cache.format_version rescue nil
    @cache = ActiveSupport::Cache::Litecache.new(path: ":memory:", sleep_interval: 60)
    @cache.clear
  end

  def teardown
    @cache&.close rescue nil
  end

  def test_does_not_mutate_global_format_version
    after = ActiveSupport::Cache.format_version rescue nil
    assert_equal @before_format, after
  end

  def test_write_read
    @cache.write("k", "v")
    assert_equal "v", @cache.read("k")
  end

  def test_write_multi_does_not_mutate_input
    data = {"a" => "1", "b" => "2"}
    original = data.dup
    @cache.write_multi(data)
    assert_equal original, data
    assert_equal "1", @cache.read("a")
  end

  def test_empty_multi
    assert_equal({}, @cache.read_multi)
    @cache.write_multi({})
  end

  def test_increment_decrement
    @cache.write("n", 1)
    @cache.increment("n", 2)
    assert_equal 3, @cache.read("n").to_i
    @cache.decrement("n", 1)
    assert_equal 2, @cache.read("n").to_i
  end

  def test_clear
    @cache.write("x", "y")
    @cache.clear
    assert_nil @cache.read("x")
  end

  def test_l1_options_pass_through
    cache = ActiveSupport::Cache::Litecache.new(
      path: ":memory:",
      sleep_interval: 60,
      l1: true,
      invalidate: :ttl,
      l1_ttl_default: 2
    )
    assert cache.l1_enabled?
    assert_equal :ttl, cache.invalidate_mode
    cache.write("a", "b")
    assert_equal "b", cache.read("a")
    assert cache.l1_stats[:enabled]
    assert cache.stats.is_a?(Hash)
    assert cache.stats[:l1] || cache.stats["l1"]
  ensure
    cache&.close rescue nil
  end

  def test_l1_off_by_default_on_store
    refute @cache.l1_enabled?
    assert_equal :none, @cache.invalidate_mode
  end
end
