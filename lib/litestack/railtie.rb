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
    # Optional path to vectorlite native extension (Litevector).
    #   config.litestack.vector_extension_path = Rails.root.join("vendor/vectorlite/linux-x86_64/vectorlite.so")
    config.litestack.vector_extension_path = nil
    # Optional path to wangfenjin/simple (libsimple) for Chinese + Pinyin FTS.
    #   config.litestack.simple_extension_path = Rails.root.join("vendor/simple/linux-x86_64/libsimple.so")
    config.litestack.simple_extension_path = nil

    # Run early so Litesupport.root resolves correctly before components open DBs.
    initializer "litestack.configure_data_path", before: :load_config_initializers do |app|
      path = app.config.litestack.data_path
      Litesupport.data_path = path if path && !path.to_s.empty?
    end

    initializer "litestack.configure_vector", after: "litestack.configure_data_path" do |app|
      path = app.config.litestack.vector_extension_path
      next if path.nil? || path.to_s.empty?
      require "litestack/litevector"
      Litevector.extension_path = path.to_s
    end

    initializer "litestack.configure_simple_tokenizer", after: "litestack.configure_data_path" do |app|
      path = app.config.litestack.simple_extension_path
      next if path.nil? || path.to_s.empty?
      require "litestack/litesearch"
      Litesearch.simple_extension_path = path.to_s
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
