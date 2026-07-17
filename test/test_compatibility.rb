# frozen_string_literal: true

require_relative "helper"
require "litestack/compatibility"

class TestCompatibility < Minitest::Test
  def test_rails_8_1_is_supported
    assert Litestack::Compatibility.rails_supported?("8.1.0")
    assert Litestack::Compatibility.rails_supported?("8.1.3")
    assert Litestack::Compatibility.rails_supported?("8.2.0")
  end

  def test_rails_below_8_1_unsupported
    refute Litestack::Compatibility.rails_supported?("8.0.0")
    refute Litestack::Compatibility.rails_supported?("7.2.0")
    refute Litestack::Compatibility.rails_supported?("7.1.0")
  end

  def test_rails_9_unsupported
    refute Litestack::Compatibility.rails_supported?("9.0.0")
  end

  def test_assert_raises_named_error_for_too_old
    err = assert_raises(Litestack::UnsupportedFrameworkVersionError) do
      Litestack::Compatibility.assert_rails_supported!("8.0.2")
    end
    assert_match(/8\.0\.2/, err.message)
    assert_match(/8\.1/, err.message)
  end

  def test_assert_raises_named_error_for_too_new
    err = assert_raises(Litestack::UnsupportedFrameworkVersionError) do
      Litestack::Compatibility.assert_rails_supported!("9.0.0")
    end
    assert_match(/9\.0\.0/, err.message)
  end

  def test_assert_succeeds_for_8_1
    assert Litestack::Compatibility.assert_rails_supported!("8.1.3")
  end

  def test_assert_raises_for_zero_version
    err = assert_raises(Litestack::UnsupportedFrameworkVersionError) do
      Litestack::Compatibility.assert_rails_supported!("0.0.0")
    end
    assert_kind_of Litestack::UnsupportedFrameworkVersionError, err
  end

  def test_requirement_constant
    assert Litestack::RAILS_REQUIREMENT.satisfied_by?(Gem::Version.new("8.1.0"))
    refute Litestack::RAILS_REQUIREMENT.satisfied_by?(Gem::Version.new("8.0.0"))
  end
end
