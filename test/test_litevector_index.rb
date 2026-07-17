# frozen_string_literal: true

require_relative "helper"
require_relative "support/vectorlite_helper"
require "litestack/litevector"
require "fileutils"

class TestLitevectorIndex < Minitest::Test
  def setup
    VectorliteHelper.skip_unless_available!(self)
    Litevector.reset_configuration!
    Litevector.extension_path = VectorliteHelper.extension_path
    @tmpdir = Dir.mktmpdir("litevector-")
    if defined?(Litesupport) && Litesupport.respond_to?(:data_path=)
      @prev_dp = Litesupport.data_path
      Litesupport.data_path = @tmpdir
      Litesupport.reset_configuration! if Litesupport.respond_to?(:reset_configuration!)
      Litesupport.data_path = @tmpdir
    end
  end

  def teardown
    @index&.close
    if defined?(Litesupport) && Litesupport.respond_to?(:reset_configuration!)
      Litesupport.reset_configuration!
    end
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    Litevector.reset_configuration!
  end

  def test_knn_returns_nearest
    @index = Litevector::Index.create(
      name: "docs",
      dimensions: 3,
      distance: :cosine,
      max_elements: 100,
      data_path: @tmpdir
    )
    @index.upsert(0, [1.0, 0.0, 0.0])
    @index.upsert(1, [0.0, 1.0, 0.0])
    hits = @index.knn([0.9, 0.1, 0.0], k: 1)
    assert_equal 1, hits.length
    assert_equal 0, hits.first[:id]
  end

  def test_save_and_reload
    @index = Litevector::Index.create(
      name: "persist",
      dimensions: 3,
      distance: :l2,
      max_elements: 50,
      data_path: @tmpdir
    )
    @index.upsert(0, [1.0, 0.0, 0.0])
    @index.upsert(1, [0.0, 1.0, 0.0])
    @index.checkpoint!
    hits = @index.knn([1.0, 0.0, 0.0], k: 1)
    assert_equal 0, hits.first[:id]
    @index.close
    @index = nil

    reopened = Litevector::Index.open(name: "persist", data_path: @tmpdir)
    hits2 = reopened.knn([1.0, 0.0, 0.0], k: 1)
    assert_equal 0, hits2.first[:id]
  ensure
    reopened&.close
  end

  def test_invalid_id_rejected
    @index = Litevector::Index.create(
      name: "ids",
      dimensions: 2,
      max_elements: 10,
      data_path: @tmpdir
    )
    assert_raises(Litevector::InvalidIdError) { @index.upsert(-1, [1.0, 0.0]) }
  end

  def test_dimension_mismatch_on_upsert
    @index = Litevector::Index.create(
      name: "dims",
      dimensions: 3,
      max_elements: 10,
      data_path: @tmpdir
    )
    assert_raises(Litevector::DimensionMismatchError) { @index.upsert(0, [1.0, 2.0]) }
  end

  def test_delete
    @index = Litevector::Index.create(
      name: "del",
      dimensions: 3,
      max_elements: 10,
      data_path: @tmpdir
    )
    @index.upsert(0, [1.0, 0.0, 0.0])
    @index.upsert(1, [0.0, 1.0, 0.0])
    @index.delete(0)
    hits = @index.knn([1.0, 0.0, 0.0], k: 1)
    assert_equal 1, hits.first[:id]
  end

  def test_connection_mixin_info
    db = SQLite3::Database.new(":memory:")
    db.extend(Litevector::Connection)
    info = db.vectorlite_info
    assert_match(/vectorlite/i, info)
  end
end
