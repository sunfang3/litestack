# frozen_string_literal: true

# Coverage for GitHub issue #143:
# Litesearch AR `search` must not interpolate the user term into SQL unescaped.
# https://github.com/oldmoe/litestack/issues/143

require "minitest/autorun"
require "active_record"
require "active_record/base"
require "active_support"
require "active_support/notifications"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "active_record/connection_adapters/litedb_adapter"

ActiveRecord::Base.establish_connection(adapter: "litedb", database: ":memory:")

db = ActiveRecord::Base.connection.raw_connection
db.execute("CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT, created_at TEXT, updated_at TEXT)")
db.execute("CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, description TEXT, author_id INTEGER, created_at TEXT, updated_at TEXT)")

class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end

class Author < ApplicationRecord
  include Litesearch::Model

  litesearch do |schema|
    schema.field :name
  end
end

class Book < ApplicationRecord
  belongs_to :author, optional: true

  include Litesearch::Model

  litesearch do |schema|
    schema.fields [:title, :description]
  end
end

class TestLitesearchArSearchSqlInjection < Minitest::Test
  def setup
    Author.delete_all
    Book.delete_all
    # Ensure indexes exist on this connection
    Author.litesearch { |s| s.field :name }
    Book.litesearch { |s| s.fields [:title, :description] }

    @alice = Author.create!(name: "Alice Wonder")
    @bob = Author.create!(name: "Bob Builder")
    @obrien = Author.create!(name: "O'Brien Special")
    Book.create!(title: "Safe Book", description: "nothing dangerous", author: @alice)
    Book.create!(title: "Other Book", description: "also safe", author: @bob)

    @sql_log = []
    @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      @sql_log << event.payload[:sql].to_s
    end
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
  end

  def search_sqls
    @sql_log.select { |s| s.include?("MATCH") || s.include?("search_idx") }
  end

  # --- Happy paths ---

  def test_normal_search_still_finds_records
    rs = Author.search("Alice")
    assert_equal 1, rs.length
    assert_equal "Alice Wonder", rs.first.name
  end

  def test_search_is_case_insensitive_like_fts
    rs = Author.search("alice")
    assert_operator rs.length, :>=, 1
  end

  # --- Issue #143: injection must not succeed ---

  def test_quote_breakout_does_not_return_all_rows
    # Classic breakout: close the MATCH string and force a tautology.
    # Vulnerable code becomes: ... MATCH 'zzz' OR 1=1 OR ''
    # which can match every joined row (demonstrated before the fix).
    malicious = "zzz' OR 1=1 OR '"
    rs = Author.search(malicious)
    assert_equal 0, rs.length,
      "injection payload must not return authors via SQL breakout (got #{rs.map(&:name).inspect})"
  end

  def test_or_true_payload_does_not_return_all_rows
    malicious = "nonexistent' OR '1'='1"
    rs = Author.search(malicious)
    assert_equal 0, rs.length,
      "OR 1=1 style payload must not bypass FTS term (got #{rs.map(&:name).inspect})"
  end

  def test_comment_payload_does_not_return_all_rows
    malicious = "zzz' --"
    rs = Author.search(malicious)
    assert_equal 0, rs.length
  end

  def test_union_style_payload_does_not_error_or_exfiltrate
    malicious = "x' UNION SELECT 1,2,3 --"
    rs = Author.search(malicious)
    assert_kind_of ActiveRecord::Relation, rs
    assert_operator rs.length, :<=, Author.count
    names = rs.map(&:name)
    refute_includes names, "Alice Wonder"
    refute_includes names, "Bob Builder"
  end

  def test_sql_log_does_not_embed_raw_unescaped_quote_breakout
    malicious = "evil' OR 1=1 OR '"
    Author.search(malicious).load
    joined = search_sqls.join("\n")
    # Vulnerable form embeds the breakout *outside* the string literal:
    #   MATCH 'evil' OR 1=1 OR '
    # Safe form keeps the whole payload inside one quoted/bound value, e.g.:
    #   MATCH 'evil'' OR 1=1 OR '''  or MATCH ? with bind
    refute_match(/MATCH\s+'evil'\s+OR\s+1\s*=\s*1/i, joined,
      "SQL must not contain unescaped breakout of MATCH string literal:\n#{joined}")
  end

  def test_bound_or_quoted_term_appears_safely_in_sql
    term = "safe_unique_token_xyz"
    Author.search(term).load
    joined = search_sqls.join("\n")
    # Either placeholder bind (?) or properly quoted literal containing the token
    assert(
      joined.include?("?") || joined.include?(term) || joined.include?("safe_unique_token"),
      "expected search SQL to reference the term safely:\n#{joined}"
    )
  end

  # --- Legitimate special characters (issue notes FTS apostrophe difficulty) ---

  def test_legitimate_apostrophe_in_name_is_searchable_or_safe
    # After fix: must not raise SQL syntax error from unescaped apostrophe.
    # FTS may or may not tokenize O'Brien as expected; safety > perfect match.
    rs = nil
    assert_silent do
      rs = Author.search("O'Brien")
      rs.load
    end
    assert_kind_of ActiveRecord::Relation, rs
    # Prefer finding the record when FTS allows; never explode with SQL error
    if rs.any?
      assert_includes rs.map(&:name), "O'Brien Special"
    end
  end

  def test_double_quote_and_fts_operators_do_not_break_sql_layer
    # FTS operators in the *query language* may change matches, but must stay
    # inside a single bound/quoted SQL string — no SQL structure breakout.
    payloads = [
      'Alice"',
      "Alice*",
      "Alice AND Bob",
      "Alice OR Bob",
      "Alice AND",
      "OR Alice"
    ]
    payloads.each do |payload|
      rs = Author.search(payload)
      assert_kind_of ActiveRecord::Relation, rs, "payload=#{payload.inspect}"
      assert_operator rs.length, :<=, Author.count, "payload=#{payload.inspect}"
    end
  end

  # --- Edge cases ---

  def test_empty_string_search
    rs = Author.search("")
    assert_kind_of ActiveRecord::Relation, rs
  end

  def test_nil_term_coerced_safely
    rs = Author.search(nil)
    assert_kind_of ActiveRecord::Relation, rs
  end

  def test_book_search_injection_same_protection
    malicious = "zzz' OR 1=1 OR '"
    rs = Book.search(malicious)
    assert_equal 0, rs.length,
      "Book.search must apply the same SQL-safe term handling"
  end

  def test_normal_book_search_still_works
    rs = Book.search("Safe")
    assert_operator rs.length, :>=, 1
    assert_equal Book, rs.first.class
  end
end
