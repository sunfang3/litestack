# frozen_string_literal: true

require_relative "helper"
require "litestack/sql_table_prefix"

describe Litestack::SqlTablePrefix do
  it "sanitizes and builds table names" do
    assert_equal "queue", Litestack::SqlTablePrefix.table_name("")
    assert_equal "queue", Litestack::SqlTablePrefix.table_name(nil)
    assert_equal "litestack_queue", Litestack::SqlTablePrefix.table_name("litestack_")
    assert_equal "litestack_queue", Litestack::SqlTablePrefix.table_name("litestack_!!!")
  end

  it "rewrites SQL identifiers" do
    sql = "INSERT INTO queue(id) VALUES (1); CREATE INDEX idx_queue_by_name ON queue(name);"
    out = Litestack::SqlTablePrefix.apply_sql_text(sql, "litestack_")
    assert_includes out, "INSERT INTO litestack_queue"
    assert_includes out, "idx_litestack_queue_by_name"
    assert_includes out, "ON litestack_queue"
    refute_match(/\bqueue\b/, out.gsub("litestack_queue", "").gsub("idx_litestack_queue_by_name", ""))
  end

  it "leaves definition unchanged for empty prefix" do
    defn = {"stmts" => {"push" => "INSERT INTO queue VALUES (1)"}}
    assert_equal defn, Litestack::SqlTablePrefix.apply_definition(defn, "")
  end
end

describe "Litequeue table_prefix" do
  it "uses unprefixed queue by default" do
    q = Litequeue.new(path: ":memory:", logger: nil)
    assert_equal "queue", q.queue_table
    q.push("v", 0, "default")
    assert_equal 1, q.count
  ensure
    q&.close rescue nil
  end

  it "stores jobs in a prefixed table" do
    q = Litequeue.new(path: ":memory:", logger: nil, table_prefix: "litestack_")
    assert_equal "litestack_queue", q.queue_table
    id, name = q.push("hello", 0, "default")
    assert id
    assert_equal "default", name
    assert_equal 1, q.count
    row = q.pop
    refute_nil row
  ensure
    q&.close rescue nil
  end
end
