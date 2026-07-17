# frozen_string_literal: true

module Litevector
  # Optional mixin for SQLite3::Database / Litedb connections.
  #
  #   db = Litedb.new(":memory:")
  #   db.extend(Litevector::Connection)
  #   db.ensure_vectorlite!
  #   idx = db.vector_index(:items) { |s| s.dimensions 8; s.max_elements 1000 }
  #
  # Note: Index still owns its own connection by default; this mixin is for
  # loading the extension on an application DB and building schemas in place.
  module Connection
    def ensure_vectorlite!
      Extension.load!(self)
      self
    end

    def vectorlite_info
      ensure_vectorlite!
      get_first_value("SELECT vectorlite_info()")
    end

    # Build or open a Litevector::Index (standalone HNSW file under Litesupport.root).
    def vector_index(name, **opts)
      if block_given?
        schema = Schema.new(name: name)
        yield schema
        schema.name = name if schema.name.nil? || schema.name.empty?
        Index.new(schema: schema, **opts).tap(&:open!)
      else
        Index.open(name: name, **opts)
      end
    end
  end
end
