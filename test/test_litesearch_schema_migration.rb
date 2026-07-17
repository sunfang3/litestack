# frozen_string_literal: true

require_relative "helper"
require "fileutils"

class TestLitesearchSchemaMigration < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("litesearch-mig-")
    @path = File.join(@dir, "search.sqlite3")
    @db = Litedb.new(@path)
    @db.execute("CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT, body TEXT)")
    @idx = @db.search_index("docs_idx") do |schema|
      schema.fields [:title, :body]
      schema.table :docs
    end
    @db.execute("INSERT INTO docs(title, body) VALUES (?, ?)", ["Hello World", "searchable ruby content"])
    @idx.rebuild! if @idx.respond_to?(:rebuild!)
  end

  def teardown
    @db&.close rescue nil
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_rebuild_creates_backup_before_mutation
    backups_before = Dir[File.join(@dir, ".litestack-backup-*.sqlite3")]
    @idx.rebuild!
    backups_after = Dir[File.join(@dir, ".litestack-backup-*.sqlite3")]
    assert_operator backups_after.size, :>, backups_before.size, "rebuild! must create a verified sidecar backup on file-backed DBs"
    backup = @idx.last_migration_backup || backups_after.max_by { |f| File.mtime(f) }
    assert File.file?(backup)
    # Source remains searchable
    rows = @db.execute("SELECT count(*) FROM docs")
    assert_equal 1, rows[0][0]
  end

  def test_rebuild_preserves_searchable_rows
    before = @db.execute("SELECT title FROM docs").flatten
    @idx.rebuild!
    after = @db.execute("SELECT title FROM docs").flatten
    assert_equal before, after
  end

  def test_in_memory_rebuild_without_backup_path
    db = Litedb.new(":memory:")
    db.execute("CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT, body TEXT)")
    idx = db.search_index("docs_idx") do |schema|
      schema.fields [:title, :body]
      schema.table :docs
    end
    db.execute("INSERT INTO docs(title, body) VALUES (?, ?)", ["a", "b"])
    idx.rebuild!
    assert_nil idx.last_migration_backup
    db.close
  end
end
