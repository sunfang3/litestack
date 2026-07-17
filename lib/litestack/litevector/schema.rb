# frozen_string_literal: true

module Litevector
  # Definition for a vector index (maps to vectorlite CREATE VIRTUAL TABLE args).
  class Schema
    DISTANCES = %i[l2 cosine ip].freeze

    attr_reader :name

    def initialize(name: nil)
      @name = name&.to_s
      @dimensions = nil
      @distance = :cosine
      @max_elements = 10_000
      @ef_construction = 200
      @m = 16
      @vector_column = "embedding"
      @index_file = nil
      @source = :embedding
    end

    def name=(value)
      @name = value.to_s
    end

    def dimensions(value = nil)
      return @dimensions if value.nil?
      n = Integer(value)
      raise ArgumentError, "dimensions must be positive" if n <= 0
      @dimensions = n
    end

    def distance(value = nil)
      return @distance if value.nil?
      sym = value.to_sym
      raise ArgumentError, "distance must be one of #{DISTANCES}" unless DISTANCES.include?(sym)
      @distance = sym
    end

    def max_elements(value = nil)
      return @max_elements if value.nil?
      n = Integer(value)
      raise ArgumentError, "max_elements must be positive" if n <= 0
      @max_elements = n
    end

    def ef_construction(value = nil)
      return @ef_construction if value.nil?
      @ef_construction = Integer(value)
    end

    def m(value = nil)
      return @m if value.nil?
      @m = Integer(value)
    end

    def vector_column(value = nil)
      return @vector_column if value.nil?
      col = value.to_s
      if %w[operation path distance rowid].include?(col)
        raise ArgumentError, "vector column name #{col.inspect} is reserved"
      end
      @vector_column = col
    end

    def index_file(value = nil)
      return @index_file if value.nil?
      @index_file = value.to_s
    end

    # Attribute / method name used by Litevector::Model for embeddings.
    def source(value = nil)
      return @source if value.nil?
      @source = value.to_sym
    end

    def validate!
      raise ArgumentError, "name is required" if name.nil? || name.empty?
      raise ArgumentError, "dimensions is required" if dimensions.nil?
      raise ArgumentError, "max_elements is required" if max_elements.nil?
      self
    end

    def table_name
      "lv_#{sanitize_ident(name)}"
    end

    def to_h
      {
        name: name,
        dimensions: dimensions,
        distance: distance,
        max_elements: max_elements,
        ef_construction: ef_construction,
        m: m,
        vector_column: vector_column,
        index_file: index_file,
        source: source
      }
    end

    def self.from_h(hash)
      h = hash.transform_keys(&:to_sym)
      s = new(name: h[:name])
      s.dimensions(h[:dimensions]) if h[:dimensions]
      s.distance(h[:distance]) if h[:distance]
      s.max_elements(h[:max_elements]) if h[:max_elements]
      s.ef_construction(h[:ef_construction]) if h[:ef_construction]
      s.m(h[:m]) if h[:m]
      s.vector_column(h[:vector_column]) if h[:vector_column]
      s.index_file(h[:index_file]) if h[:index_file]
      s.source(h[:source]) if h[:source]
      s
    end

    # SQL fragment for CREATE VIRTUAL TABLE ... USING vectorlite(...)
    def create_module_args(index_path:)
      validate!
      col = "#{vector_column} float32[#{dimensions}] #{distance}"
      hnsw = "hnsw(max_elements=#{max_elements}, ef_construction=#{ef_construction}, M=#{m})"
      path_sql = sql_quote(File.expand_path(index_path))
      "#{col}, #{hnsw}, #{path_sql}"
    end

    private

    def sanitize_ident(str)
      str.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
    end

    def sql_quote(str)
      "'#{str.to_s.gsub("'", "''")}'"
    end
  end
end
