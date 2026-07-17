# frozen_string_literal: true

require_relative "helper"
require "litestack/litevector"

class TestLitevectorVector < Minitest::Test
  def test_pack_array_float32_le
    bin = Litevector::Vector.pack([1.0, 2.0, 3.0])
    assert_equal 12, bin.bytesize
    assert_equal [1.0, 2.0, 3.0], Litevector::Vector.unpack(bin)
  end

  def test_pack_with_dimensions
    bin = Litevector::Vector.pack([1.0, 2.0], dimensions: 2)
    assert_equal 8, bin.bytesize
  end

  def test_dimension_mismatch
    err = assert_raises(Litevector::DimensionMismatchError) do
      Litevector::Vector.pack([1.0, 2.0], dimensions: 3)
    end
    assert_match(/length 2 != 3/, err.message)
  end

  def test_reject_nan
    assert_raises(ArgumentError) { Litevector::Vector.pack([Float::NAN]) }
  end

  def test_reject_infinity
    assert_raises(ArgumentError) { Litevector::Vector.pack([Float::INFINITY]) }
  end

  def test_pack_binary_passthrough
    raw = [1.0, 2.0].pack("e*")
    assert_equal raw, Litevector::Vector.pack(raw, dimensions: 2)
  end

  def test_binary_dimension_mismatch
    raw = [1.0].pack("e*")
    assert_raises(Litevector::DimensionMismatchError) do
      Litevector::Vector.pack(raw, dimensions: 3)
    end
  end
end
