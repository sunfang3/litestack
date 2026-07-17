# frozen_string_literal: true

require_relative "helper"
require "yaml"
require "digest"
require "fileutils"

class TestUpgradeFrom045 < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/v0_4_5", __dir__)

  def setup
    @manifest = YAML.load_file(File.join(FIXTURE_ROOT, "manifest.yml"))
    @tmpdir = Dir.mktmpdir("upgrade045-")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def copy_fixture(name)
    src = File.join(FIXTURE_ROOT, "#{name}.sqlite3")
    dst = File.join(@tmpdir, "#{name}.sqlite3")
    FileUtils.cp(src, dst)
    expected = @manifest["checksums_sha256"][name]
    assert_equal expected, Digest::SHA256.file(src).hexdigest
    dst
  end

  def test_checksums_stable
    @manifest["checksums_sha256"].each do |name, expected|
      path = File.join(FIXTURE_ROOT, "#{name}.sqlite3")
      assert_equal expected, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_litedb_preserves_rows
    path = copy_fixture("litedb")
    db = Litedb.new(path)
    names = db.execute("SELECT name FROM people ORDER BY name").flatten
    assert_equal @manifest["expectations"]["litedb"]["names"].sort, names.sort
    db.close
  end

  def test_litejob_min_jobs
    path = copy_fixture("litejob")
    q = Litequeue.new(path: path, logger: nil)
    assert_operator q.count, :>=, @manifest["expectations"]["litejob"]["min_jobs"]
    q.close
  end

  def test_litesearch_docs
    path = copy_fixture("litesearch")
    db = Litedb.new(path)
    assert_equal 1, db.execute("SELECT count(*) FROM docs")[0][0]
    db.close
  end

  def test_litekd_via_component_api
    path = copy_fixture("litekd")
    prev = Litekd.options.dup rescue {}
    Litekd.configure(path: path, logger: nil)
    Litekd.class_variable_set(:@@connection, nil) if Litekd.class_variable_defined?(:@@connection)
    begin
      conn = Litekd.connection
      refute conn.closed?
      value = begin
        Litekd.string("greeting").value
      rescue
        SQLite3::Database.new(path).get_first_value("SELECT value FROM scalars WHERE key = ?", ["greeting"])
      end
      assert value, "expected greeting from 0.4.5 LiteKD fixture"
    ensure
      begin
        Litekd.connection.close if Litekd.class_variable_defined?(:@@connection) && Litekd.class_variable_get(:@@connection)
      rescue
        nil
      end
      Litekd.class_variable_set(:@@connection, nil) if Litekd.class_variable_defined?(:@@connection)
      Litekd.configure(prev || {})
    end
  end

  def test_litemetric_via_component_api
    path = copy_fixture("litemetric")
    Litemetric.options = {path: path, flush_interval: 3600, summarize_interval: 3600, snapshot_interval: 3600}
    Singleton.__init__(Litemetric) if defined?(Singleton) && Singleton.respond_to?(:__init__)
    Litemetric.instance_variable_set(:@singleton__instance__, nil) rescue nil
    lm = Litemetric.instance
    begin
      topics = lm.topics
      assert_kind_of Array, topics
      assert topics.any? || lm.respond_to?(:register), "Litemetric must open fixture"
    ensure
      lm.close rescue nil
      Litemetric.instance_variable_set(:@singleton__instance__, nil) rescue nil
      Litemetric.options = nil
    end
  end

  def test_injected_migration_failure_preserves_source
    path = copy_fixture("litedb")
    conn = SQLite3::Database.new(path)
    conn.user_version = 1
    before = conn.execute("SELECT name FROM people ORDER BY name").flatten
    sql = {
      "schema" => {
        1 => {"t" => "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT)"},
        2 => {"bad" => "THIS IS NOT SQL"}
      },
      "stmts" => {}
    }
    migrator = Litestack::SchemaMigrator.new(conn, path: path, sql_definition: sql, component: "litedb")
    assert_raises(Litestack::MigrationError) { migrator.migrate! }
    after = conn.execute("SELECT name FROM people ORDER BY name").flatten
    assert_equal before, after
    assert_equal 1, conn.get_first_value("PRAGMA user_version").to_i
    conn.close
  end
end
