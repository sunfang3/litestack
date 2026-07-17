# frozen_string_literal: true

require_relative "helper"
require "litestack/liteboard/liteboard"

class TestLiteboardComponents < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("liteboard-c-")
    @path = File.join(@dir, "metrics.sqlite3")
    Litemetric.options = {path: @path, flush_interval: 3600, summarize_interval: 3600, snapshot_interval: 3600}
    Singleton.__init__(Litemetric) if defined?(Singleton) && Singleton.respond_to?(:__init__)
    Litemetric.instance_variable_set(:@singleton__instance__, nil) rescue nil
    @lm = Litemetric.instance
  end

  def teardown
    @lm&.close rescue nil
    FileUtils.rm_rf(@dir)
  end

  def env(path)
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new(""),
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "9292"
    }
  end

  %w[Litecache Litedb Litejob Litecable].each do |topic|
    define_method("test_empty_#{topic.downcase}") do
      status, _h, body = Liteboard.app.call(env("/topics/#{topic}"))
      html = body.join
      assert_equal 200, status, "#{topic} should render"
      assert_match(/<main/, html)
      refute_match(/(?<![a-zA-Z])NaN(?![a-zA-Z])|Infinity/, html)
    end
  end
end
