# frozen_string_literal: true

# Pure unit coverage for Litevector::Schema (no native extension required).

require_relative "helper"
require "litestack/litevector"

class TestLitevectorSchema < Minitest::Test
  def test_defaults_and_setters
    s = Litevector::Schema.new(name: "docs")
    assert_equal "docs", s.name
    assert_equal :cosine, s.distance
    assert_equal 10_000, s.max_elements
    assert_equal 200, s.ef_construction
    assert_equal 16, s.m
    assert_equal "embedding", s.vector_column
    assert_equal :embedding, s.source

    s.dimensions 8
    s.distance :l2
    s.max_elements 100
    s.ef_construction 50
    s.m 8
    s.vector_column "vec"
    s.index_file "/tmp/x.hnsw"
    s.source :embedding_vector

    assert_equal 8, s.dimensions
    assert_equal :l2, s.distance
    assert_equal 100, s.max_elements
    assert_equal 50, s.ef_construction
    assert_equal 8, s.m
    assert_equal "vec", s.vector_column
    assert_equal "/tmp/x.hnsw", s.index_file
    assert_equal :embedding_vector, s.source
  end

  def test_validate_requires_name_and_dimensions
    s = Litevector::Schema.new
    err = assert_raises(ArgumentError) { s.validate! }
    assert_match(/name/, err.message)

    s.name = "x"
    err = assert_raises(ArgumentError) { s.validate! }
    assert_match(/dimensions/, err.message)

    s.dimensions 4
    assert_same s, s.validate!
  end

  def test_invalid_dimensions_and_distance
    s = Litevector::Schema.new(name: "n")
    assert_raises(ArgumentError) { s.dimensions 0 }
    assert_raises(ArgumentError) { s.dimensions(-1) }
    assert_raises(ArgumentError) { s.max_elements 0 }
    assert_raises(ArgumentError) { s.distance :manhattan }
  end

  def test_reserved_vector_column_names
    s = Litevector::Schema.new(name: "n")
    %w[operation path distance rowid].each do |col|
      assert_raises(ArgumentError) { s.vector_column col }
    end
  end

  def test_table_name_sanitizes
    s = Litevector::Schema.new(name: "My Index!")
    assert_equal "lv_my_index_", s.table_name
  end

  def test_to_h_and_from_h_roundtrip
    s = Litevector::Schema.new(name: "docs")
    s.dimensions 3
    s.distance :ip
    s.max_elements 9
    s.ef_construction 10
    s.m 4
    s.vector_column "emb"
    s.index_file "/tmp/a.hnsw"
    s.source :blob

    h = s.to_h
    s2 = Litevector::Schema.from_h(h.transform_keys(&:to_s))
    assert_equal s.to_h, s2.to_h
  end

  def test_create_module_args
    s = Litevector::Schema.new(name: "docs")
    s.dimensions 3
    s.distance :cosine
    s.max_elements 50
    args = s.create_module_args(index_path: "/tmp/idx'file.hnsw")
    assert_match(/embedding float32\[3\] cosine/, args)
    assert_match(/hnsw\(max_elements=50/, args)
    assert_match(/''/, args) # escaped quote in path
  end

  def test_getters_without_args
    s = Litevector::Schema.new(name: "n")
    s.dimensions 2
    assert_equal 2, s.dimensions
    assert_equal :cosine, s.distance
    assert_equal 10_000, s.max_elements
    assert_equal 200, s.ef_construction
    assert_equal 16, s.m
    assert_equal "embedding", s.vector_column
    assert_nil s.index_file
    assert_equal :embedding, s.source
  end
end
