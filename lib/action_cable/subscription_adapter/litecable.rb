# frozen_string_literal: true

require_relative "../../litestack/compatibility"
Litestack::Compatibility.assert_rails_supported!

require_relative "../../litestack/litecable"
require "action_cable"
require "action_cable/subscription_adapter/channel_prefix"
require "action_cable/subscription_adapter/base"

module ActionCable
  module SubscriptionAdapter
    class Litecable < ::Litecable # :nodoc:
      attr_reader :logger, :server

      prepend ChannelPrefix

      def initialize(server, logger = nil)
        @server = server
        @logger = logger || (server.respond_to?(:logger) ? server.logger : Logger.new(IO::NULL))
        config_path = if server.respond_to?(:config) && server.config.respond_to?(:cable)
          server.config.cable&.dig("config_path") || "./config/litecable.yml"
        else
          "./config/litecable.yml"
        end
        cable_cfg = if server.respond_to?(:config) && server.config.respond_to?(:cable)
          server.config.cable
        end
        path = cable_cfg&.dig("path")
        opts = {config_path: config_path, logger: @logger}
        opts[:path] = path if path
        # Optional Honker transport: transport: honker in cable.yml / litecable.yml
        if (transport = cable_cfg&.dig("transport") || cable_cfg&.dig(:transport))
          opts[:transport] = transport
        end
        if (poll_ms = cable_cfg&.dig("watcher_poll_interval_ms") || cable_cfg&.dig(:watcher_poll_interval_ms))
          opts[:watcher_poll_interval_ms] = poll_ms
        end
        super(opts)
      end

      def shutdown
        close
      end
    end
  end
end
