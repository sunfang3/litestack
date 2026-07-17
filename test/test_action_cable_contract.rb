# frozen_string_literal: true

require_relative "helper"
require "logger"
require "action_cable"
require "action_cable/subscription_adapter/litecable"

class TestActionCableContract < Minitest::Test
  FakeConfig = Struct.new(:cable)
  FakeServer = Struct.new(:logger, :config)

  def setup
    @path, @dir = tmp_sqlite_path("cable-contract")
  end

  def teardown
    @adapter&.shutdown rescue nil
    @adapter&.close rescue nil
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_subscribe_broadcast_unsubscribe_shutdown
    server = FakeServer.new(Logger.new(IO::NULL), FakeConfig.new({"path" => @path}))
    @adapter = ActionCable::SubscriptionAdapter::Litecable.new(server)
    received = []
    callback = ->(msg) { received << msg }
    @adapter.subscribe("room", callback)
    @adapter.broadcast("room", "ping")
    sleep 0.1
    assert_includes received, "ping"
    @adapter.unsubscribe("room", callback)
    @adapter.shutdown
    @adapter.shutdown # idempotent
  end

  def test_no_prefix_no_subscribers
    server = FakeServer.new(Logger.new(IO::NULL), FakeConfig.new({"path" => @path}))
    @adapter = ActionCable::SubscriptionAdapter::Litecable.new(server)
    @adapter.broadcast("empty", "x")
    @adapter.shutdown
  end
end
