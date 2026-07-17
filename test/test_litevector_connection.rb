# frozen_string_literal: true

require_relative "helper"
require_relative "support/vectorlite_helper"
require "litestack/litevector"
require "sqlite3"
require "fileutils"

class TestLitevectorConnection < Minitest::Test
  def setup
    VectorliteHelper.skip_unless_available!(self)
    Litevector.reset_configuration!
    Litevector.extension_path = VectorliteHelper.extension_path
    @tmpdir = Dir.mktmpdir("litevector-conn-")
  end

  def teardown
    @idx&.close rescue nil
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    Litevector.reset_configuration!
  end

  def test_ensure_vectorlite_and_info
    db = SQLite3::Database.new(":memory:")
    db.extend(Litevector::Connection)
    assert_same db, db.ensure_vectorlite!
    info = db.vectorlite_info
    assert_match(/vectorlite/i, info.to_s)
  end

  def test_vector_index_with_block
    db = SQLite3::Database.new(":memory:")
    db.extend(Litevector::Connection)
    @idx = db.vector_index(:items, data_path: @tmpdir) do |s|
      s.dimensions 3
      s.distance :l2
      s.max_elements 50
    end
    @idx.upsert(0, [1.0, 0.0, 0.0])
    hits = @idx.knn([1.0, 0.0, 0.0], k: 1)
    assert_equal 0, hits.first[:id]
  end

  def test_vector_index_open_without_block
    db = SQLite3::Database.new(":memory:")
    db.extend(Litevector::Connection)
    created = db.vector_index(:reopen_me, data_path: @tmpdir) do |s|
      s.dimensions 3
      s.max_elements 20
    end
    created.upsert(1, [0.0, 1.0, 0.0])
    created.checkpoint!
    created.close

    reopened = db.vector_index(:reopen_me, data_path: @tmpdir)
    hits = reopened.knn([0.0, 1.0, 0.0], k: 1)
    assert_equal 1, hits.first[:id]
    reopened.close
  end
end
