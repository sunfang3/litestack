# frozen_string_literal: true

# Unit coverage for Litevector::Index without a real vectorlite .so.

require_relative "helper"
require "litestack/litevector"
require "fileutils"
require "json"

class FakeVectorDb
  attr_reader :sql, :closed

  def initialize
    @sql = []
    @closed = false
    @data = {}
  end

  def execute(sql, binds = [])
    binds = Array(binds)
    @sql << sql
    if sql =~ /INSERT INTO/i && binds.size >= 2
      @data[binds[0]] = binds[1]
    elsif sql =~ /DELETE FROM/i && binds.size >= 1
      @data.delete(binds[0])
    elsif sql =~ /SELECT rowid, distance/i
      k = (binds[1] || 10).to_i
      @data.keys.first(k).map { |id| [id, 0.0] }
    else
      []
    end
  end

  def close
    @closed = true
  end
end

class TestLitevectorIndexUnit < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("lv-unit-")
    @fake = FakeVectorDb.new
    @db_new = SQLite3::Database.method(:new)
    @ext_load = Litevector::Extension.method(:load!)

    fake = @fake
    SQLite3::Database.define_singleton_method(:new) { |*_a, **_k| fake }
    Litevector::Extension.define_singleton_method(:load!) { |_db| "/fake/vectorlite.so" }
    Litevector.reset_configuration!
  end

  def teardown
    SQLite3::Database.define_singleton_method(:new, @db_new)
    Litevector::Extension.define_singleton_method(:load!, @ext_load)
    Litevector.reset_configuration!
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_create_open_upsert_delete_knn_checkpoint
    idx = Litevector::Index.create(
      name: "unit_docs",
      dimensions: 3,
      distance: :l2,
      max_elements: 20,
      data_path: @tmpdir
    )
    assert idx.open?
    refute idx.closed?

    assert_equal 0, idx.upsert(0, [1.0, 0.0, 0.0])
    assert_equal 1, idx.upsert(1, [0.0, 1.0, 0.0])
    hits = idx.knn([1.0, 0.0, 0.0], k: 2, ef: 20)
    assert_equal 2, hits.size
    assert_equal 0, hits.first[:id]

    idx.delete(1)
    assert_raises(Litevector::InvalidIdError) { idx.upsert(-1, [1.0, 0.0, 0.0]) }
    assert_raises(Litevector::DimensionMismatchError) { idx.upsert(2, [1.0, 2.0]) }

    assert File.file?(File.join(@tmpdir, "vector", "unit_docs.json"))

    idx.checkpoint!
    assert idx.open?

    assert_equal File.join(@tmpdir, "vector", "unit_docs.hnsw"), idx.path
    idx.close
    assert idx.closed?
    assert_raises(Litevector::IndexNotOpenError) { idx.upsert(0, [1.0, 0.0, 0.0]) }
  end

  def test_open_missing_metadata
    err = assert_raises(Litevector::IndexNotOpenError) do
      Litevector::Index.open(name: "nope", data_path: @tmpdir)
    end
    assert_match(/no metadata/, err.message)
  end

  def test_open_existing_metadata
    schema = Litevector::Schema.new(name: "exist")
    schema.dimensions 3
    schema.max_elements 10
    root = File.join(@tmpdir, "vector")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "exist.json"), JSON.generate(schema.to_h))

    idx = Litevector::Index.open(name: "exist", data_path: @tmpdir)
    assert idx.open?
    idx.close
  end

  def test_vector_root_and_sanitize
    assert_match(/vector/, Litevector::Index.vector_root(@tmpdir))
    assert_equal "my_name_", Litevector::Index.sanitize("My Name!")
  end

  def test_knn_rejects_bad_k
    idx = Litevector::Index.create(name: "k", dimensions: 2, max_elements: 5, data_path: @tmpdir)
    assert_raises(ArgumentError) { idx.knn([1.0, 0.0], k: 0) }
    idx.close
  end

  def test_info
    idx = Litevector::Index.create(name: "info", dimensions: 2, max_elements: 5, data_path: @tmpdir)
    Litevector::Extension.define_singleton_method(:info) { |_db| "vectorlite ok" }
    assert_equal "vectorlite ok", idx.info
    idx.close
  ensure
    Litevector::Extension.define_singleton_method(:load!) { |_db| "/fake/vectorlite.so" }
  end

  def test_initialize_from_hash_schema
    idx = Litevector::Index.new(
      schema: {name: "h", dimensions: 2, max_elements: 5, distance: :cosine},
      data_path: @tmpdir
    )
    idx.open!
    assert idx.open?
    idx.close
  end
end
