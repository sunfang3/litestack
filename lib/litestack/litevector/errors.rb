# frozen_string_literal: true

module Litevector
  class Error < StandardError; end

  class ExtensionNotFoundError < Error; end
  class ExtensionLoadError < Error; end
  class DimensionMismatchError < Error; end
  class InvalidIdError < Error; end
  class IndexNotOpenError < Error; end
  class PersistenceError < Error; end
end
