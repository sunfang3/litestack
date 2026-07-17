# frozen_string_literal: true

require_relative "helper"

class TestLitemetric < Minitest::Test
  def setup
    @path, @dir = tmp_sqlite_path("metrics")
    # Reset singleton so we get a fresh metrics DB for this path
    Litemetric.instance_variable_set(:@singleton__instance__, nil) if Litemetric.respond_to?(:instance_variable_set)
    Litemetric.options = {path: @path, flush_interval: 60, summarize_interval: 60, snapshot_interval: 3600, metrics: false}
    @lm = Litemetric.instance
  end

  def teardown
    @lm&.close rescue nil
    Litemetric.instance_variable_set(:@singleton__instance__, nil) if Litemetric.respond_to?(:instance_variable_set)
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_register_and_capture
    @lm.register("TestTopic")
    @lm.capture("TestTopic", "hit", "k1", 1.0)
    @lm.instance_variable_get(:@collector).flush
    topics = @lm.topics
    assert topics.any? { |t| t[0] == "TestTopic" || t.include?("TestTopic") }
  end

  def test_empty_topics
    list = @lm.topics
    assert_kind_of Array, list
  end

  def test_double_close
    @lm.close
    @lm.close
  end
end
