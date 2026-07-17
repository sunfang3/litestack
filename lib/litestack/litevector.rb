# frozen_string_literal: true

# Optional vector search component (vectorlite HNSW extension).
# Require explicitly: require "litestack/litevector"
# Does not load as part of require "litestack".

require_relative "litevector/errors"
require_relative "litevector/vector"
require_relative "litevector/extension"
require_relative "litevector/schema"
require_relative "litevector/index"
require_relative "litevector/connection"
require_relative "litevector/model"

module Litevector
  class << self
    # Filesystem path to vectorlite.so / .dylib / .dll
    attr_accessor :extension_path

    # When true (default), Index#close flushes via connection close.
    attr_writer :auto_save

    def auto_save
      return true if @auto_save.nil?
      @auto_save
    end

    def configure
      yield self if block_given?
      self
    end

    def reset_configuration!
      @extension_path = nil
      @auto_save = true
    end

    def available?
      Extension.available?
    end
  end

  reset_configuration!
end
