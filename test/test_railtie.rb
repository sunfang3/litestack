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

  # Issues #136 / #128: older railties assigned sqlite3_production_warning= without a guard
  # and blew up on Rails 7.2+/8 when the config API moved or vanished.
  def test_disable_sqlite_warning_is_safe_without_config_method
    ar_config = Object.new
    def ar_config.respond_to?(meth, include_all = false)
      return false if meth == :sqlite3_production_warning=
      return false if meth == :sqlite3
      super
    end
    app = Struct.new(:config).new(Struct.new(:active_record).new(ar_config))

    assert_silent { Litestack::Railtie.disable_sqlite_production_warning!(app) }
  end

  def test_disable_sqlite_warning_when_config_present
    ar_config = Object.new
    def ar_config.respond_to?(meth, include_all = false)
      return true if meth == :sqlite3_production_warning=
      super
    end
    def ar_config.sqlite3_production_warning=(value)
      @warning = value
    end
    def ar_config.sqlite3_production_warning
      @warning
    end
    app = Struct.new(:config).new(Struct.new(:active_record).new(ar_config))

    Litestack::Railtie.disable_sqlite_production_warning!(app)
    assert_equal false, ar_config.sqlite3_production_warning
  end

  # Issue #130: Rails 8 needs sqlite3 >= 2; litestack 1.0 must not pin sqlite3 < 2.
  def test_gemspec_allows_sqlite3_2_x
    gemspec_path = File.expand_path("../litestack.gemspec", __dir__)
    spec = Gem::Specification.load(gemspec_path)
    sqlite = spec.dependencies.find { |d| d.name == "sqlite3" }
    refute_nil sqlite, "expected sqlite3 runtime dependency"
    req = sqlite.requirement
    assert req.satisfied_by?(Gem::Version.new("2.0.0")), "sqlite3 2.0.0 must be allowed (got #{req})"
    assert req.satisfied_by?(Gem::Version.new("2.7.0")), "sqlite3 2.x must be allowed (got #{req})"
    refute req.satisfied_by?(Gem::Version.new("1.6.9")), "sqlite3 1.x is outside 1.0 support (got #{req})"
  end
end
