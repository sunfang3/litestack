# frozen_string_literal: true

# Litesearch::SimpleExtension unit coverage without libsimple binary.

require_relative "helper"
require "litestack/litesearch"
require "sqlite3"
require "fileutils"

class TestSimpleExtensionUnit < Minitest::Test
  def setup
    @prev = Litesearch.simple_extension_path
    @prev_env = ENV["LITESEARCH_SIMPLE_EXTENSION_PATH"]
    Litesearch.reset_simple_configuration!
    ENV.delete("LITESEARCH_SIMPLE_EXTENSION_PATH")
    ENV.delete("SIMPLE_EXTENSION_PATH")
  end

  def teardown
    Litesearch.simple_extension_path = @prev
    if @prev_env.nil?
      ENV.delete("LITESEARCH_SIMPLE_EXTENSION_PATH")
    else
      ENV["LITESEARCH_SIMPLE_EXTENSION_PATH"] = @prev_env
    end
  end

  def test_platform_key_and_basenames
    key = Litesearch::SimpleExtension.platform_key
    assert key.is_a?(String)
    assert Litesearch::SimpleExtension.basenames.include?("libsimple.so")
    dirs = Litesearch::SimpleExtension.vendor_dirs
    assert dirs.any? { |d| d.include?("simple") }
  end

  def test_candidate_paths_include_explicit
    Litesearch.simple_extension_path = "/tmp/custom/libsimple.so"
    paths = Litesearch::SimpleExtension.candidate_paths
    assert_includes paths, "/tmp/custom/libsimple.so"
  end

  def test_resolve_and_load_missing
    Litesearch::SimpleExtension.stub(:vendored_candidates, []) do
      Litesearch.simple_extension_path = "/no/libsimple.so"
      assert_raises(Litesearch::SimpleExtension::NotFoundError) do
        Litesearch::SimpleExtension.resolve_path
      end
    end
  end

  def test_load_error_on_bad_binary
    path = File.join(Dir.mktmpdir, "libsimple.so")
    File.write(path, "not-a-dylib")
    Litesearch.simple_extension_path = path
    db = SQLite3::Database.new(":memory:")
    assert_raises(Litesearch::SimpleExtension::LoadError) do
      Litesearch::SimpleExtension.load!(db)
    end
  ensure
    FileUtils.rm_rf(File.dirname(path)) if path
  end

  def test_dict_path_for
    dir = Dir.mktmpdir
    so = File.join(dir, "libsimple.so")
    File.write(so, "x")
    assert_nil Litesearch::SimpleExtension.dict_path_for(so)
    FileUtils.mkdir_p(File.join(dir, "dict"))
    assert_equal File.join(dir, "dict"), Litesearch::SimpleExtension.dict_path_for(so)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_simple_available_predicate
    Litesearch::SimpleExtension.stub(:candidate_paths, ["/nope"]) do
      refute Litesearch.simple_available?
    end
  end

  def test_fts_query_expr_for_simple_builders
    %i[simple jieba raw].each do |builder|
      schema = Litesearch::Schema.new
      schema.schema[:name] = :t
      schema.fields [:text]
      schema.tokenizer :simple
      schema.query_builder builder
      schema.post_init
      sql = schema.sql_for(:search)
      case builder
      when :simple then assert_match(/simple_query/, sql)
      when :jieba then assert_match(/jieba_query/, sql)
      when :raw then refute_match(/simple_query|jieba_query/, sql)
      end
    end
  end
end
