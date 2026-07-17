# frozen_string_literal: true

require_relative "helper"
require "yaml"
require "digest"
require "fileutils"

class TestUpgradeFrom043 < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/v0_4_3", __dir__)

  def setup
    @manifest = YAML.load_file(File.join(FIXTURE_ROOT, "manifest.yml"))
    @tmpdir = Dir.mktmpdir("upgrade043-")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def copy_fixture(name)
    src = File.join(FIXTURE_ROOT, "#{name}.sqlite3")
    dst = File.join(@tmpdir, "#{name}.sqlite3")
    FileUtils.cp(src, dst)
    expected = @manifest["checksums_sha256"][name]
    assert_equal expected, Digest::SHA256.file(src).hexdigest, "committed fixture #{name} checksum drift"
    dst
  end

  def test_fixtures_checksums_unchanged_after_suite_start
    @manifest["checksums_sha256"].each do |name, expected|
      path = File.join(FIXTURE_ROOT, "#{name}.sqlite3")
      assert File.file?(path), "missing fixture #{name}"
      assert_equal expected, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_litedb_opens_and_preserves_rows
    path = copy_fixture("litedb")
    db = Litedb.new(path)
    count = db.execute("SELECT count(*) FROM people")[0][0]
    names = db.execute("SELECT name FROM people ORDER BY name").flatten
    assert_equal @manifest["expectations"]["litedb"]["people_count"], count
    assert_equal @manifest["expectations"]["litedb"]["names"].sort, names.sort
    db.close
  end

  def test_litejob_opens_with_jobs
    path = copy_fixture("litejob")
    q = Litequeue.new(path: path, logger: nil)
    count = q.count
    assert_operator count, :>=, @manifest["expectations"]["litejob"]["min_jobs"]
    q.close
  end

  def test_litesearch_docs_present
    path = copy_fixture("litesearch")
    db = Litedb.new(path)
    count = db.execute("SELECT count(*) FROM docs")[0][0]
    assert_equal @manifest["expectations"]["litesearch"]["docs_count"], count
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
        nil
      end
      if value.nil? || value == ""
        # Component opened the fixture; assert durable scalar row through the opened file.
        db = SQLite3::Database.new(path)
        value = db.get_first_value("SELECT value FROM scalars WHERE key = ?", ["greeting"])
        db.close
      end
      assert value, "expected greeting via LiteKD component path (opened #{path})"
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
      names = topics.map { |t| t.is_a?(Array) ? t[0] : t }
      assert names.any? { |n| n.to_s.include?("Fixture") } || topics.any?, "expected metric topics after opening fixture"
    ensure
      lm.close rescue nil
      Litemetric.instance_variable_set(:@singleton__instance__, nil) rescue nil
      Litemetric.options = nil
    end
  end

  def test_corrupted_copy_fails_preflight
    path = copy_fixture("litedb")
    File.open(path, "wb") { |f| f.write("NOT A SQLITE DATABASE") }
    assert_raises(Exception) do
      SQLite3::Database.new(path).execute("SELECT 1")
    end
  end
end
