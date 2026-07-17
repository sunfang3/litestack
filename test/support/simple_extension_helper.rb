# frozen_string_literal: true

module SimpleExtensionHelper
  module_function

  def extension_path
    candidates = [
      ENV["LITESEARCH_SIMPLE_EXTENSION_PATH"],
      ENV["SIMPLE_EXTENSION_PATH"],
      File.expand_path("../../vendor/simple/linux-x86_64/libsimple.so", __dir__),
      File.expand_path("../../vendor/simple/darwin-arm64/libsimple.dylib", __dir__),
      File.expand_path("../../vendor/simple/darwin-x86_64/libsimple.dylib", __dir__)
    ].compact
    candidates.find { |p| File.file?(p) }
  end

  def available?
    !extension_path.nil?
  end

  def skip_unless_available!(test)
    test.skip "libsimple not available (run scripts/fetch_simple.rb)" unless available?
  end
end
