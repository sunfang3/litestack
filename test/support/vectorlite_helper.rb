# frozen_string_literal: true

require "fileutils"

module VectorliteHelper
  module_function

  def extension_path
    candidates = [
      ENV["LITEVECTOR_EXTENSION_PATH"],
      File.expand_path("../../vendor/vectorlite/linux-x86_64/vectorlite.so", __dir__),
      File.expand_path("../../vendor/vectorlite/darwin-arm64/vectorlite.dylib", __dir__),
      File.expand_path("../../vendor/vectorlite/darwin-x86_64/vectorlite.dylib", __dir__)
    ].compact
    candidates.find { |p| File.file?(p) }
  end

  def available?
    !extension_path.nil?
  end

  def skip_unless_available!(test)
    test.skip "vectorlite extension not available (run scripts/fetch_vectorlite.rb)" unless available?
  end

  def with_extension_env
    path = extension_path
    prev = ENV["LITEVECTOR_EXTENSION_PATH"]
    ENV["LITEVECTOR_EXTENSION_PATH"] = path if path
    yield path
  ensure
    if prev.nil?
      ENV.delete("LITEVECTOR_EXTENSION_PATH")
    else
      ENV["LITEVECTOR_EXTENSION_PATH"] = prev
    end
  end
end
