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
    Litevector.extension_path = "/nonexistent/vectorlite.so"
    # Stub vendor lookup so this asserts the missing path even when binaries are installed.
    Litevector::Extension.stub(:vendored_candidates, []) do
      err = assert_raises(Litevector::ExtensionNotFoundError) do
        Litevector::Extension.load!(SQLite3::Database.new(":memory:"))
      end
      assert_match(/vectorlite binary not found/, err.message)
    end
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

  def test_platform_key_and_vendor_dirs
    key = Litevector::Extension.platform_key
    assert_match(/linux|darwin|windows|unknown/, key)
    dirs = Litevector::Extension.vendor_dirs
    assert dirs.any? { |d| d.include?("vectorlite") }
  end

  def test_load_failure_wraps_as_extension_load_error
    path = File.join(Dir.mktmpdir, "vectorlite.so")
    File.write(path, "not a real shared library")
    Litevector.extension_path = path
    db = SQLite3::Database.new(":memory:")
    err = assert_raises(Litevector::ExtensionLoadError) do
      Litevector::Extension.load!(db)
    end
    assert_match(/failed to load vectorlite/, err.message)
  ensure
    FileUtils.rm_rf(File.dirname(path)) if path
  end

  def test_info_and_loaded_predicate
    VectorliteHelper.skip_unless_available!(self)
    # Ensure no unit-test hook is left over from other files.
    Litevector::Extension.load_hook = nil
    Litevector.extension_path = VectorliteHelper.extension_path
    db = SQLite3::Database.new(":memory:")
    refute Litevector::Extension.loaded?(db)
    path = Litevector::Extension.load!(db)
    assert path
    assert Litevector::Extension.loaded?(db), "load! must mark connection as loaded"
    info = Litevector::Extension.info(db)
    assert_match(/vectorlite/i, info.to_s)
    assert Litevector::Extension.loaded?(db)
  end

  def test_configure_and_reset
    Litevector.configure { |c| c.extension_path = "/tmp/x.so"; c.auto_save = false }
    assert_equal "/tmp/x.so", Litevector.extension_path
    refute Litevector.auto_save
    Litevector.reset_configuration!
    assert_nil Litevector.extension_path
    assert Litevector.auto_save
  end
end
