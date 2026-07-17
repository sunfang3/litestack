# frozen_string_literal: true

require_relative "compatibility"
Litestack::Compatibility.assert_rails_supported!

require "rails/railtie"

module Litestack
  class Railtie < ::Rails::Railtie
    # Application config for Litestack (issue #34):
    #   config.litestack.data_path = Rails.root.join("storage")
    config.litestack = ActiveSupport::OrderedOptions.new
    config.litestack.data_path = nil

    # Run early so Litesupport.root resolves correctly before components open DBs.
    initializer "litestack.configure_data_path", before: :load_config_initializers do |app|
      path = app.config.litestack.data_path
      Litesupport.data_path = path if path && !path.to_s.empty?
    end

    initializer :litestack_disable_production_sqlite_warning do |app|
      ActiveSupport.on_load(:active_record) do
        # Issues #136 / #128: never assume sqlite3_production_warning= exists
        # (removed / relocated across Rails 7.2 → 8.x).
        Litestack::Railtie.disable_sqlite_production_warning!(app)
      end
    end

    # Safe no-op when the host Rails version has no production SQLite warning config.
    def self.disable_sqlite_production_warning!(app)
      ar = app.config.active_record
      if ar.respond_to?(:sqlite3_production_warning=)
        ar.sqlite3_production_warning = false
      elsif ar.respond_to?(:sqlite3) && ar.sqlite3.respond_to?(:production_warning=)
        ar.sqlite3.production_warning = false
      end
      nil
    end
  end
end
