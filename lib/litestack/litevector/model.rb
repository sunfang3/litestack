# frozen_string_literal: true

module Litevector
  # Active Record integration (optional).
  #
  #   class Document < ApplicationRecord
  #     include Litevector::Model
  #     litevector do |schema|
  #       schema.dimensions 1536
  #       schema.distance :cosine
  #       schema.max_elements 100_000
  #       schema.source :embedding
  #     end
  #   end
  #
  #   Document.nearest_neighbors(query_vector, k: 10)
  #   document.reindex_vector!
  module Model
    def self.included(base)
      base.extend(ClassMethods)
    end

    def reindex_vector!
      raise ArgumentError, "record must be persisted" unless self.class.primary_key && id
      vector = public_send(self.class.litevector_source)
      self.class.litevector_index.upsert(id, vector)
    end

    def remove_vector!
      return unless self.class.primary_key && id
      self.class.litevector_index.delete(id)
    end

    module ClassMethods
      def litevector_index
        @litevector_index
      end

      def litevector_source
        @litevector_source || :embedding
      end

      def litevector(&block)
        schema = Schema.new(name: litevector_default_name)
        yield schema if block
        schema.name = litevector_default_name if schema.name.nil? || schema.name.empty?
        schema.validate!
        @litevector_source = schema.source || :embedding
        @litevector_index = Index.new(schema: schema).tap(&:open!)
        @litevector_index
      end

      def nearest_neighbors(vector, k: 10, ef: nil)
        raise "litevector not configured for #{name}" unless @litevector_index
        hits = @litevector_index.knn(vector, k: k, ef: ef)
        ids = hits.map { |h| h[:id] }
        return none if ids.empty?

        pk = primary_key
        records = where(pk => ids).to_a
        by_id = records.index_by { |r| r.public_send(pk) }
        # Preserve knn order
        ordered = ids.filter_map { |i| by_id[i] }
        # Distance annotation (non-persisted)
        ordered.each_with_index do |rec, i|
          rec.define_singleton_method(:vector_distance) { hits[i][:distance] }
        end
        ordered
      end

      private

      def litevector_default_name
        "ar_#{table_name}"
      end
    end
  end
end
