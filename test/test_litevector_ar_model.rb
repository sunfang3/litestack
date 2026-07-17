# frozen_string_literal: true

# ActiveRecord Litevector::Model — namespaced to avoid polluting global Author/Book.

require_relative "helper"
require_relative "support/vectorlite_helper"
require "active_record"
require "active_record/base"
require "litestack/litevector"

module LitevectorArFixture
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  class Document < ApplicationRecord
    self.table_name = "litevector_docs"

    include Litevector::Model
  end
end

class TestLitevectorArModel < Minitest::Test
  Document = LitevectorArFixture::Document

  def setup
    VectorliteHelper.skip_unless_available!(self)
    Litevector.reset_configuration!
    Litevector.extension_path = VectorliteHelper.extension_path
    @tmpdir = Dir.mktmpdir("litevector-ar-")
    Litesupport.data_path = @tmpdir if defined?(Litesupport)

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    db = ActiveRecord::Base.connection.raw_connection
    db.execute("CREATE TABLE litevector_docs(id INTEGER PRIMARY KEY, title TEXT, embedding BLOB)")

    Document.litevector do |schema|
      schema.dimensions 3
      schema.distance :cosine
      schema.max_elements 100
      schema.source :embedding_vector
    end

    # Store embeddings as JSON text for the test accessor
    Document.class_eval do
      def embedding_vector
        JSON.parse(self[:embedding])
      end

      def embedding_vector=(arr)
        self[:embedding] = JSON.generate(arr)
      end
    end
  end

  def teardown
    Document.litevector_index&.close
    Litesupport.reset_configuration! if defined?(Litesupport) && Litesupport.respond_to?(:reset_configuration!)
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    Litevector.reset_configuration!
  end

  def test_nearest_neighbors_orders_by_distance
    d0 = Document.create!(title: "x", embedding: JSON.generate([1.0, 0.0, 0.0]))
    d1 = Document.create!(title: "y", embedding: JSON.generate([0.0, 1.0, 0.0]))
    d0.reindex_vector!
    d1.reindex_vector!

    results = Document.nearest_neighbors([0.95, 0.05, 0.0], k: 2)
    assert_equal 2, results.length
    assert_equal d0.id, results.first.id
    assert results.first.respond_to?(:vector_distance)
  end
end
