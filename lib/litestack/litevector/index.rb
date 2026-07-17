# frozen_string_literal: true

require "fileutils"
require "json"
require "sqlite3"

module Litevector
  # Standalone HNSW vector index backed by vectorlite virtual tables.
  #
  # Persistence (vectorlite 0.2.0): index file path is given at CREATE time;
  # the graph is flushed when the SQLite connection closes.
  class Index
    DEFAULT_EF = 10

    attr_reader :schema, :options

    # Create a new index (overwrites schema metadata; reuses HNSW file if present).
    def self.create(name:, dimensions:, distance: :cosine, max_elements: 10_000, **opts)
      schema = Schema.new(name: name)
      schema.dimensions(dimensions)
      schema.distance(distance)
      schema.max_elements(max_elements)
      opts.each do |k, v|
        schema.public_send(k, v) if schema.respond_to?(k)
      end
      new(schema: schema, **opts).tap(&:open!)
    end

    # Open an existing index (reads schema JSON if present).
    def self.open(name:, **opts)
      root = vector_root(opts[:data_path])
      meta_path = File.join(root, "#{sanitize(name)}.json")
      unless File.file?(meta_path)
        raise IndexNotOpenError, "no metadata for index #{name.inspect} at #{meta_path}"
      end
      schema = Schema.from_h(JSON.parse(File.read(meta_path)))
      new(schema: schema, **opts).tap(&:open!)
    end

    def self.vector_root(data_path = nil)
      base = if data_path
        Pathname.new(data_path)
      elsif defined?(Litesupport) && Litesupport.respond_to?(:root)
        Litesupport.root
      else
        Pathname.new(".")
      end
      path = base.join("vector")
      FileUtils.mkdir_p(path)
      path.to_s
    end

    def self.sanitize(name)
      name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
    end

    def initialize(schema:, data_path: nil, db_path: nil, index_file: nil, auto_save: nil, extension_path: nil)
      @schema = schema.is_a?(Schema) ? schema : Schema.from_h(schema)
      @schema.validate!
      @data_path = data_path
      @root = self.class.vector_root(data_path)
      # Default :memory: shell — durable state is the .hnsw index file + .json metadata.
      # Avoid DROP TABLE on a file-backed DB: vectorlite 0.2.0 deletes the HNSW file on DROP.
      @db_path = db_path || ":memory:"
      @index_file = index_file || @schema.index_file || File.join(@root, "#{@schema.name}.hnsw")
      @schema.index_file(@index_file)
      @auto_save = auto_save.nil? ? Litevector.auto_save : auto_save
      @extension_path = extension_path
      @db = nil
      @dirty = false
      @closed = true
    end

    def open!
      return self if open?

      prev = Litevector.extension_path
      Litevector.extension_path = @extension_path if @extension_path

      FileUtils.mkdir_p(File.dirname(@index_file)) unless @index_file.start_with?(":")
      FileUtils.mkdir_p(@root)

      @db = SQLite3::Database.new(@db_path)
      Extension.load!(@db)
      # CREATE binds/loads HNSW from index_file when the file exists (v0.2.0).
      # Do not DROP first — DROP deletes the index file.
      args = @schema.create_module_args(index_path: @index_file)
      @db.execute("CREATE VIRTUAL TABLE #{table_sql} USING vectorlite(#{args})")
      write_metadata!
      @closed = false
      @dirty = false
      self
    ensure
      Litevector.extension_path = prev if @extension_path
    end

    def closed?
      @closed || @db.nil?
    end

    def open?
      !closed?
    end

    def upsert(id, vector)
      ensure_open!
      rid = normalize_id(id)
      blob = Vector.pack(vector, dimensions: @schema.dimensions)
      col = @schema.vector_column
      # replace: delete then insert (vectorlite update needs sqlite>=3.38 rowid filter)
      @db.execute("DELETE FROM #{table_sql} WHERE rowid = ?", [rid])
      @db.execute("INSERT INTO #{table_sql}(rowid, #{col}) VALUES (?, ?)", [rid, blob])
      @dirty = true
      rid
    end

    def delete(id)
      ensure_open!
      rid = normalize_id(id)
      @db.execute("DELETE FROM #{table_sql} WHERE rowid = ?", [rid])
      @dirty = true
      rid
    end

    # @return [Array<Hash>] list of {id:, distance:}
    def knn(query, k: 10, ef: nil)
      ensure_open!
      k = Integer(k)
      raise ArgumentError, "k must be positive" if k <= 0
      blob = Vector.pack(query, dimensions: @schema.dimensions)
      col = @schema.vector_column
      sql = if ef
        "SELECT rowid, distance FROM #{table_sql} WHERE knn_search(#{col}, knn_param(?, ?, ?))"
      else
        "SELECT rowid, distance FROM #{table_sql} WHERE knn_search(#{col}, knn_param(?, ?))"
      end
      binds = ef ? [blob, k, Integer(ef)] : [blob, k]
      @db.execute(sql, binds).map do |row|
        {id: row[0], distance: row[1]}
      end
    end

    def info
      ensure_open!
      Extension.info(@db)
    end

    # Flush HNSW to disk by closing and reopening the connection (vectorlite 0.2.0).
    def checkpoint!
      ensure_open!
      flush_close_reopen!
      self
    end

    def close
      return self if @closed
      begin
        @db&.close
      rescue => e
        raise PersistenceError, "failed closing vector index: #{e.class}: #{e.message}"
      ensure
        @db = nil
        @closed = true
        @dirty = false
      end
      self
    end

    attr_reader :db_path

    def path
      @index_file
    end

    private

    def ensure_open!
      raise IndexNotOpenError, "index #{@schema.name.inspect} is closed" if closed?
    end

    def table_sql
      quote_ident(@schema.table_name)
    end

    def quote_ident(name)
      %("#{name.to_s.gsub('"', '""')}")
    end

    def write_metadata!
      meta = File.join(@root, "#{@schema.name}.json")
      File.write(meta, JSON.pretty_generate(@schema.to_h))
    end

    def normalize_id(id)
      rid = Integer(id)
      raise InvalidIdError, "vectorlite rowid must be >= 0 (got #{rid})" if rid < 0
      rid
    rescue ArgumentError, TypeError
      raise InvalidIdError, "vector id must be an integer, got #{id.inspect}"
    end

    def flush_close_reopen!
      # Closing the connection flushes HNSW to index_file (v0.2.0).
      @db.close
      @db = nil
      @db = SQLite3::Database.new(@db_path)
      Extension.load!(@db)
      args = @schema.create_module_args(index_path: @index_file)
      @db.execute("CREATE VIRTUAL TABLE #{table_sql} USING vectorlite(#{args})")
      @dirty = false
    end
  end
end
