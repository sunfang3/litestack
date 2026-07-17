# frozen_string_literal: true

require_relative "compatibility"
Litestack::Compatibility.assert_rails_supported!

require "rails/railtie"

module Litestack
  class Railtie < ::Rails::Railtie
    initializer :litestack_disable_production_sqlite_warning do |app|
      ActiveSupport.on_load(:active_record) do
        if app.config.active_record.respond_to?(:sqlite3_production_warning=)
          app.config.active_record.sqlite3_production_warning = false
        elsif app.config.active_record.respond_to?(:sqlite3) && app.config.active_record.sqlite3.respond_to?(:production_warning=)
          # Rails 8.1 nested config path if present
          begin
            app.config.active_record.sqlite3.production_warning = false
          rescue
            nil
          end
        end
      end
    end
  end
end
