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
end
