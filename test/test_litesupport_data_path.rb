# frozen_string_literal: true

# Coverage for GitHub issues #91 and #34:
# - #91: LITESTACK_DATA_PATH must apply even when set after litestack is required
#   (dotenv / late ENV), so components do not split files across default + env paths.
# - #34: allow programmatic Litesupport.data_path= / configure without ENV.
# https://github.com/oldmoe/litestack/issues/91
# https://github.com/oldmoe/litestack/issues/34

require_relative "helper"
require "fileutils"

class TestLitesupportDataPath < Minitest::Test
  def setup
    @prev_env = ENV["LITESTACK_DATA_PATH"]
    ENV.delete("LITESTACK_DATA_PATH")
    Litesupport.reset_configuration!
    @tmpdir = Dir.mktmpdir("litestack-data-")
  end

  def teardown
    Litesupport.reset_configuration!
    if @prev_env.nil?
      ENV.delete("LITESTACK_DATA_PATH")
    else
      ENV["LITESTACK_DATA_PATH"] = @prev_env
    end
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  # --- #34: programmatic configuration ---

  def test_data_path_setter_affects_root
    Litesupport.data_path = @tmpdir
    root = Litesupport.root("test")
    assert_equal Pathname.new(@tmpdir).join("test").expand_path.to_s,
      root.expand_path.to_s
  end

  def test_configure_block_sets_data_path
    Litesupport.configure { |c| c.data_path = @tmpdir }
    assert_equal @tmpdir, Litesupport.data_path
    assert_operator Litesupport.root("development").to_s, :include?, @tmpdir
  end

  def test_configured_data_path_takes_precedence_over_env
    ENV["LITESTACK_DATA_PATH"] = File.join(@tmpdir, "from-env")
    Litesupport.data_path = File.join(@tmpdir, "from-config")
    root = Litesupport.root("production")
    assert_match(/from-config/, root.to_s)
    refute_match(/from-env/, root.to_s)
  end

  def test_reset_configuration_falls_back_to_env
    Litesupport.data_path = File.join(@tmpdir, "cfg")
    Litesupport.reset_configuration!
    ENV["LITESTACK_DATA_PATH"] = File.join(@tmpdir, "env-only")
    root = Litesupport.root("test")
    assert_match(/env-only/, root.to_s)
  end

  # --- #91: late ENV (simulate dotenv after require) ---

  def test_late_env_is_honored_by_new_component_paths
    # At this point litestack is already required (via helper) with no ENV —
    # mirrors dotenv loading *after* Bundler.require.
    ENV["LITESTACK_DATA_PATH"] = @tmpdir
    Litesupport.reset_configuration! # clear any memoized env

    cache = Litecache.new(sleep_interval: 60, metrics: false, logger: nil)
    path = cache.options[:path].to_s
    cache.close

    assert_operator path, :include?, @tmpdir,
      "Litecache path must use late LITESTACK_DATA_PATH (got #{path})"
    refute_match(%r{(^|/)\./db/}, path, "must not fall back to ./db after ENV is set")
  end

  def test_components_share_same_root_after_late_env
    ENV["LITESTACK_DATA_PATH"] = @tmpdir
    Litesupport.reset_configuration!

    cache = Litecache.new(sleep_interval: 60, metrics: false, logger: nil)
    queue = Litequeue.new(logger: nil)
    cache_dir = File.dirname(cache.options[:path].to_s)
    queue_dir = File.dirname(queue.options[:path].to_s)
    cache.close
    queue.close

    assert_equal cache_dir, queue_dir,
      "cache and queue must land in the same data root (issue #91 dual-path bug)"
    assert_operator cache_dir, :include?, @tmpdir
  end

  def test_default_options_path_is_lazy_not_load_time
    # Class constant must not freeze a Pathname from load time
    path_default = Litecache::DEFAULT_OPTIONS[:path]
    assert path_default.respond_to?(:call),
      "DEFAULT_OPTIONS[:path] should be a callable lazy resolver, got #{path_default.class}"

    ENV["LITESTACK_DATA_PATH"] = @tmpdir
    Litesupport.reset_configuration!
    resolved = path_default.call.to_s
    assert_operator resolved, :include?, @tmpdir
  end

  def test_explicit_path_option_still_wins
    ENV["LITESTACK_DATA_PATH"] = @tmpdir
    Litesupport.data_path = File.join(@tmpdir, "cfg")
    explicit = File.join(@tmpdir, "custom-cache.sqlite3")
    cache = Litecache.new(path: explicit, sleep_interval: 60, metrics: false, logger: nil)
    assert_equal explicit, cache.options[:path].to_s
    cache.close
  end
end
