# frozen_string_literal: true

require_relative "helper"
require "rails"
require "litestack/railtie"

class TestRailtie < Minitest::Test
  def test_railtie_is_rails_railtie
    assert Litestack::Railtie < Rails::Railtie
  end

  def test_compatibility_loaded_with_railtie
    assert Litestack::Compatibility.rails_supported?(Rails::VERSION::STRING)
  end

  def test_railtie_exposes_litestack_data_path_config
    assert Litestack::Railtie.config.respond_to?(:litestack)
    assert Litestack::Railtie.config.litestack.respond_to?(:data_path)
  end
end
