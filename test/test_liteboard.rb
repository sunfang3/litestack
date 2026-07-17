# frozen_string_literal: true

require_relative "helper"
require "litestack/liteboard/liteboard"
require "tmpdir"
require "fileutils"

class TestLiteboard < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("liteboard-")
    @path = File.join(@dir, "metrics.sqlite3")
    # Seed a metrics DB
    Litemetric.options = {path: @path, flush_interval: 3600, summarize_interval: 3600, snapshot_interval: 3600}
    reset_litemetric_singleton!
    @lm = Litemetric.instance
    @lm.register("Litecache")
  end

  def teardown
    @lm&.close rescue nil
    reset_litemetric_singleton!
    FileUtils.rm_rf(@dir)
  end

  def reset_litemetric_singleton!
    if defined?(Singleton) && Litemetric.included_modules.include?(Singleton)
      Singleton.__init__(Litemetric) if Singleton.respond_to?(:__init__)
    end
    Litemetric.instance_variable_set(:@singleton__instance__, nil) rescue nil
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

  def test_index_success
    status, headers, body = Liteboard.app.call(rack_env("/"))
    html = body.join
    assert_equal 200, status
    assert_match(%r{text/html}, headers["content-type"] || headers["Content-Type"])
    assert headers["content-security-policy"] || headers["Content-Security-Policy"]
    assert_match(/liteboard/, html)
    assert_match(/<main/, html)
    assert_match(/<nav/, html)
    assert_match(/role="banner"|<header/, html)
  end

  def test_empty_metrics_state
    status, _headers, body = Liteboard.app.call(rack_env("/"))
    html = body.join
    assert_equal 200, status
    assert_match(/No metrics yet|Topics/i, html)
  end

  def test_unknown_route_404
    status, headers, body = Liteboard.app.call(rack_env("/nope"))
    html = body.join
    assert_equal 404, status
    assert_match(/Not found|no page/i, html)
    assert_match(%r{text/html}, headers["content-type"] || headers["Content-Type"])
  end

  def test_security_headers
    _status, headers, _body = Liteboard.app.call(rack_env("/"))
    csp = headers["content-security-policy"] || headers["Content-Security-Policy"]
    assert_match(/default-src 'self'/, csp)
    assert_match(/script-src 'self'/, csp)
    refute_match(/cdn\.|googleapis|gstatic/, csp)
  end

  def test_hostile_search_escaped
    status, _headers, body = Liteboard.app.call(rack_env("/", "search=%3Cscript%3Ealert(1)%3C%2Fscript%3E"))
    html = body.join
    assert_equal 200, status
    refute_match(/<script>alert/, html)
  end

  def test_asset_css
    status, headers, body = Liteboard.app.call(rack_env("/assets/liteboard.css"))
    assert_equal 200, status
    assert_match(%r{text/css}, headers["content-type"] || headers["Content-Type"])
    assert_match(/lb-shell/, body.join)
  end

  def test_asset_js_no_eval
    status, headers, body = Liteboard.app.call(rack_env("/assets/liteboard.js"))
    assert_equal 200, status
    js = body.join
    refute_match(/\beval\s*\(/, js)
    assert_match(/JSON\.parse/, js)
  end

  def test_component_litecache_empty
    status, _headers, body = Liteboard.app.call(rack_env("/topics/Litecache"))
    html = body.join
    assert_equal 200, status
    assert_match(/Litecache|cache|metric|empty|0/i, html)
  end
end
