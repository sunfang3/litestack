# frozen_string_literal: true

require_relative "helper"

class TestSchemaMigrator < Minitest::Test
  def schema_def(*versions)
    schema = {}
    versions.each_with_index do |stmts, i|
      schema[i + 1] = stmts
    end
    {"schema" => schema, "stmts" => {}}
  end

  def test_noop_when_current
    with_tmp_db("mig") do |path|
      conn = SQLite3::Database.new(path)
      conn.execute("CREATE TABLE data(id INTEGER PRIMARY KEY, v TEXT)")
      conn.user_version = 1
      sql = schema_def({"c1" => "CREATE TABLE IF NOT EXISTS data(id INTEGER PRIMARY KEY, v TEXT)"})
      migrator = Litestack::SchemaMigrator.new(conn, path: path, sql_definition: sql, component: "test")
      result = migrator.migrate!
      assert_equal 1, result[:from]
      assert_equal 1, result[:to]
      assert_nil result[:backup]
      assert_empty result[:steps]
      conn.close
    end
  end

  def test_additive_multi_version_preserves_rows
    with_tmp_db("mig2") do |path|
      conn = SQLite3::Database.new(path)
      sql = {
        "schema" => {
          1 => {"t" => "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)"},
          2 => {"c" => "ALTER TABLE items ADD COLUMN note TEXT"}
        },
        "stmts" => {}
      }
      # Bootstrap v1 manually then upgrade to v2
      conn.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)")
      conn.execute("INSERT INTO items(name) VALUES ('a')")
      conn.user_version = 1
      migrator = Litestack::SchemaMigrator.new(conn, path: path, sql_definition: sql, component: "test", destructive_versions: [])
      result = migrator.migrate!
      assert_equal 1, result[:from]
      assert_equal 2, result[:to]
      rows = conn.execute("SELECT name FROM items")
      assert_equal [["a"]], rows
      assert_equal 2, conn.get_first_value("PRAGMA user_version")
      conn.close
    end
  end

  def test_invalid_yaml_raises
    assert_raises(Litestack::InvalidMigrationError) do
      Litestack::SchemaMigrator.validate_definition!({})
    end
  end

  def test_forbidden_sql_rejected_before_write
    with_tmp_db("migforbid") do |path|
      conn = SQLite3::Database.new(path)
      conn.execute("CREATE TABLE items(id INTEGER PRIMARY KEY)")
      conn.user_version = 1
      sql = {
        "schema" => {
          1 => {"t" => "CREATE TABLE items(id INTEGER PRIMARY KEY)"},
          2 => {"bad" => "VACUUM"}
        },
        "stmts" => {}
      }
      migrator = Litestack::SchemaMigrator.new(conn, path: path, sql_definition: sql, component: "test")
      assert_raises(Litestack::InvalidMigrationError) { migrator.migrate! }
      assert_equal 1, conn.get_first_value("PRAGMA user_version").to_i
      conn.close
    end
  end

  def test_backup_uses_independent_source_and_hardlink_publish
    with_tmp_db("migbak") do |path|
      conn = SQLite3::Database.new(path)
      conn.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)")
      conn.execute("INSERT INTO items(name) VALUES ('wal-row')")
      conn.user_version = 1
      sql = {
        "schema" => {
          1 => {"t" => "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)"},
          2 => {"n" => "CREATE TABLE IF NOT EXISTS meta(k TEXT)"}
        },
        "stmts" => {}
      }
      migrator = Litestack::SchemaMigrator.new(
        conn, path: path, sql_definition: sql, component: "test", destructive_versions: [2]
      )
      result = migrator.migrate!
      assert result[:backup]
      assert File.file?(result[:backup])
      # Snapshot contains pre-mutation committed rows
      snap = SQLite3::Database.new(result[:backup], readonly: true)
      assert_equal [["wal-row"]], snap.execute("SELECT name FROM items")
      assert_equal [["ok"]], snap.execute("PRAGMA integrity_check")
      assert_empty snap.execute("PRAGMA foreign_key_check")
      snap.close
      conn.close
    end
  end

  def test_injected_failure_preserves_source
    with_tmp_db("migfail") do |path|
      conn = SQLite3::Database.new(path)
      conn.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)")
      conn.execute("INSERT INTO items(name) VALUES ('keep')")
      conn.user_version = 1
      sql = {
        "schema" => {
          1 => {"t" => "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)"},
          2 => {"bad" => "CREATE TABLE items(this is not valid SQL syntax !!!)"}
        },
        "stmts" => {}
      }
      migrator = Litestack::SchemaMigrator.new(conn, path: path, sql_definition: sql, component: "test")
      assert_raises(Litestack::MigrationError) { migrator.migrate! }
      # Original must still be usable
      rows = conn.execute("SELECT name FROM items")
      assert_equal [["keep"]], rows
      assert_equal 1, conn.get_first_value("PRAGMA user_version").to_i
      conn.close
    end
  end

  def test_destructive_creates_backup
    with_tmp_db("migdest") do |path|
      conn = SQLite3::Database.new(path)
      conn.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)")
      conn.execute("INSERT INTO items(name) VALUES ('x')")
      conn.user_version = 1
      sql = {
        "schema" => {
          1 => {"t" => "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)"},
          2 => {"n" => "CREATE TABLE IF NOT EXISTS meta(k TEXT)"}
        },
        "stmts" => {}
      }
      migrator = Litestack::SchemaMigrator.new(
        conn, path: path, sql_definition: sql, component: "test", destructive_versions: [2]
      )
      result = migrator.migrate!
      assert result[:backup]
      assert File.file?(result[:backup])
      assert_equal 2, result[:to]
      conn.close
    end
  end
end
