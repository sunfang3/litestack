# frozen_string_literal: true

# Litevector::Model unit tests without native extension (inject fake index).

require_relative "helper"
require "active_record"
require "active_record/base"
require "litestack/litevector"
require "fileutils"

module LitevectorModelUnitFixture
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  class Doc < ApplicationRecord
    self.table_name = "lv_unit_docs"
    include Litevector::Model

    def embedding
      JSON.parse(self[:embedding_json])
    end
  end
end

class TestLitevectorModelUnit < Minitest::Test
  Doc = LitevectorModelUnitFixture::Doc

  def setup
    @tmpdir = Dir.mktmpdir("lv-model-")
    Litesupport.data_path = @tmpdir if defined?(Litesupport)

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.connection.raw_connection.execute(
      "CREATE TABLE lv_unit_docs(id INTEGER PRIMARY KEY, embedding_json TEXT)"
    )

    @fake_index = Object.new
    def @fake_index.upsert(id, vec)
      @last = [id, vec]
    end
    def @fake_index.delete(id)
      @deleted = id
    end
    def @fake_index.knn(_vec, k: 10, ef: nil)
      [{id: 1, distance: 0.1}, {id: 2, distance: 0.2}].first(k)
    end
    def @fake_index.close
    end

    # Wire model state without calling Index.new/open! (avoids extension).
    Doc.instance_variable_set(:@litevector_index, @fake_index)
    Doc.instance_variable_set(:@litevector_source, :embedding)
  end

  def teardown
    Litesupport.reset_configuration! if defined?(Litesupport) && Litesupport.respond_to?(:reset_configuration!)
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_reindex_and_remove_vector
    d = Doc.create!(id: 5, embedding_json: JSON.generate([1.0, 0.0, 0.0]))
    d.reindex_vector!
    assert_equal [5, [1.0, 0.0, 0.0]], @fake_index.instance_variable_get(:@last)

    d.remove_vector!
    assert_equal 5, @fake_index.instance_variable_get(:@deleted)
  end

  def test_nearest_neighbors_orders_and_annotates
    Doc.create!(id: 1, embedding_json: JSON.generate([1.0, 0.0, 0.0]))
    Doc.create!(id: 2, embedding_json: JSON.generate([0.0, 1.0, 0.0]))

    results = Doc.nearest_neighbors([1.0, 0.0, 0.0], k: 2)
    assert_equal [1, 2], results.map(&:id)
    assert results.first.respond_to?(:vector_distance)
    assert_in_delta 0.1, results.first.vector_distance, 0.0001
  end

  def test_nearest_neighbors_empty
    def @fake_index.knn(*)
      []
    end
    rs = Doc.nearest_neighbors([1.0, 0.0, 0.0], k: 5)
    assert_equal 0, rs.length
  end

  def test_reindex_requires_persisted
    d = Doc.new(embedding_json: JSON.generate([1.0, 0.0, 0.0]))
    assert_raises(ArgumentError) { d.reindex_vector! }
  end

  def test_litevector_source_reader
    assert_equal :embedding, Doc.litevector_source
    assert_same @fake_index, Doc.litevector_index
  end
end
