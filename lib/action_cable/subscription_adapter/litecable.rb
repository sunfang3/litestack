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
        path = if server.respond_to?(:config) && server.config.respond_to?(:cable)
          server.config.cable&.dig("path")
        end
        opts = {config_path: config_path, logger: @logger}
        opts[:path] = path if path
        super(opts)
      end

      def shutdown
        close
      end
    end
  end
end
