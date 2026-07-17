# frozen_string_literal: true

require_relative "helper"

class TestLitedb < Minitest::Test
  def test_query_insert_select
    db = Litedb.new(":memory:")
    db.execute("CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT)")
    db.execute("INSERT INTO people(name) VALUES (?), (?)", ["ann", "bob"])
    rows = db.execute("SELECT name FROM people ORDER BY name")
    assert_equal [["ann"], ["bob"]], rows
    db.close
  end

  def test_transaction
    db = Litedb.new(":memory:")
    db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")
    db.transaction do
      db.execute("INSERT INTO t(v) VALUES (1)")
      db.execute("INSERT INTO t(v) VALUES (2)")
    end
    assert_equal 2, db.execute("SELECT count(*) FROM t")[0][0]
    db.close
  end

  def test_size_and_schema_count
    db = Litedb.new(":memory:")
    db.execute("CREATE TABLE t(id INTEGER)")
    assert_operator db.size, :>=, 0
    assert_equal 1, db.schema_object_count("table")
    db.close
  end

  def test_error_on_bad_sql
    db = Litedb.new(":memory:")
    assert_raises(SQLite3::SQLException) { db.execute("NOT VALID SQL") }
    db.close
  end
end
