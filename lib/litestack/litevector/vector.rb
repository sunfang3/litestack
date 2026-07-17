# frozen_string_literal: true

module Litevector
  # float32 little-endian packing for vectorlite (c-style float array as BLOB).
  module Vector
    module_function

    # @param values [Array<Numeric>, String]
    # @param dimensions [Integer, nil] when set, length must match
    # @return [String] binary float32 LE
    def pack(values, dimensions: nil)
      case values
      when String
        bin = values.b
        if dimensions && bin.bytesize != dimensions * 4
          raise DimensionMismatchError,
            "binary vector length #{bin.bytesize} != #{dimensions * 4} bytes (#{dimensions} dims)"
        end
        bin
      when Array
        if dimensions && values.length != dimensions
          raise DimensionMismatchError,
            "vector length #{values.length} != #{dimensions}"
        end
        values.each_with_index do |v, i|
          f = Float(v)
          if f.nan? || f.infinite?
            raise ArgumentError, "vector[#{i}] is not a finite float (#{f})"
          end
        end
        values.map { |v| Float(v) }.pack("e*")
      else
        raise ArgumentError, "vector must be Array or binary String, got #{values.class}"
      end
    end

    # @param binary [String]
    # @return [Array<Float>]
    def unpack(binary)
      binary.to_s.b.unpack("e*")
    end

    def dimensions_of(binary)
      binary.to_s.b.bytesize / 4
    end
  end
end
