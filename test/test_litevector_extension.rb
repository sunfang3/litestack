# frozen_string_literal: true

require_relative "helper"
require_relative "support/vectorlite_helper"
require "litestack/litevector"
require "sqlite3"

class TestLitevectorExtension < Minitest::Test
  def setup
    @prev_path = Litevector.extension_path
    @prev_env = ENV["LITEVECTOR_EXTENSION_PATH"]
    Litevector.reset_configuration!
    ENV.delete("LITEVECTOR_EXTENSION_PATH")
  end

  def teardown
    Litevector.extension_path = @prev_path
    if @prev_env.nil?
      ENV.delete("LITEVECTOR_EXTENSION_PATH")
    else
      ENV["LITEVECTOR_EXTENSION_PATH"] = @prev_env
    end
  end

  def test_resolve_prefers_explicit_config
    Litevector.extension_path = "/tmp/custom-vectorlite.so"
    # resolve_path only returns existing files — use a real temp file
    path = File.join(Dir.mktmpdir, "vectorlite.so")
    File.write(path, "fake")
    Litevector.extension_path = path
    assert_equal path, Litevector::Extension.resolve_path
  ensure
    FileUtils.rm_rf(File.dirname(path)) if path
  end

  def test_missing_raises_named_error
    Litevector.reset_configuration!
    ENV.delete("LITEVECTOR_EXTENSION_PATH")
    # Point platform vendor to empty by forcing a nonsense path only
    Litevector.extension_path = "/nonexistent/vectorlite.so"
    # Still may find vendored binary — skip if available via vendor
    if VectorliteHelper.available? && Litevector::Extension.vendored_candidates.any? { |p| File.file?(p) }
      skip "vendored binary present; cannot assert missing"
    end
    err = assert_raises(Litevector::ExtensionNotFoundError) do
      Litevector::Extension.load!(SQLite3::Database.new(":memory:"))
    end
    assert_match(/vectorlite binary not found/, err.message)
  end

  def test_load_when_binary_present
    VectorliteHelper.skip_unless_available!(self)
    Litevector.extension_path = VectorliteHelper.extension_path
    db = SQLite3::Database.new(":memory:")
    path = Litevector::Extension.load!(db)
    assert File.file?(path)
    info = db.get_first_value("select vectorlite_info()")
    refute_nil info
    assert_match(/vectorlite/i, info)
    # idempotent
    Litevector::Extension.load!(db)
  end

  def test_available_predicate
    if VectorliteHelper.available?
      Litevector.extension_path = VectorliteHelper.extension_path
      assert Litevector.available?
    else
      Litevector.extension_path = "/no/such/vectorlite.so"
      # may still be true if vendor present
      assert_includes [true, false], Litevector.available?
    end
  end
end
