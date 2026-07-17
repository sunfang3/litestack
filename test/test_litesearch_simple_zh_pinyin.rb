# frozen_string_literal: true

# Chinese + Pinyin FTS via wangfenjin/simple (tokenizer :simple).
# https://github.com/wangfenjin/simple

require_relative "helper"
require_relative "support/simple_extension_helper"
require "litestack/litedb"
require "litestack/litesearch"

class TestLitesearchSimpleZhPinyin < Minitest::Test
  def setup
    SimpleExtensionHelper.skip_unless_available!(self)
    Litesearch.reset_simple_configuration!
    Litesearch.simple_extension_path = SimpleExtensionHelper.extension_path
    @db = Litedb.new(":memory:")
    @db.results_as_hash = true
  end

  def teardown
    @db&.close rescue nil
    Litesearch.reset_simple_configuration!
  end

  def test_tokenizer_simple_is_registered
    assert Litesearch::Schema::TOKENIZERS.key?(:simple)
    assert_equal "simple", Litesearch::Schema::TOKENIZERS[:simple]
  end

  def test_chinese_phrase_search_with_simple_query
    idx = @db.search_index(:articles) do |schema|
      schema.fields [:title, :body]
      schema.tokenizer :simple
    end

    idx.add(rowid: 1, title: "国歌", body: "中华人民共和国国歌")
    idx.add(rowid: 2, title: "名胜", body: "北京天安门广场")

    # Substring-style Chinese query (simple_query expands tokens)
    hits = idx.search("中华国歌")
    ids = hits.map { |h| h["rowid"] || h[:rowid] || h[0] }
    assert_includes ids, 1
    refute_includes ids, 2
  end

  def test_pinyin_search
    idx = @db.search_index(:places) do |schema|
      schema.fields [:name]
      schema.tokenizer :simple
    end

    idx.add(rowid: 1, name: "中华人民共和国")
    idx.add(rowid: 2, name: "日本东京")

    hits = idx.search("zhonghua")
    ids = hits.map { |h| h["rowid"] || h[:rowid] || h[0] }
    assert_includes ids, 1
    refute_includes ids, 2
  end

  def test_search_sql_uses_simple_query
    schema = Litesearch::Schema.new
    schema.schema[:name] = :t
    schema.fields [:text]
    schema.tokenizer :simple
    schema.post_init
    sql = schema.sql_for(:search)
    assert_match(/simple_query\(:term\)/, sql)
  end

  def test_jieba_query_builder_sql
    schema = Litesearch::Schema.new
    schema.schema[:name] = :t
    schema.fields [:text]
    schema.tokenizer :simple
    schema.query_builder :jieba
    schema.post_init
    sql = schema.sql_for(:search)
    assert_match(/jieba_query\(:term\)/, sql)
  end

  def test_porter_search_sql_unchanged
    schema = Litesearch::Schema.new
    schema.schema[:name] = :t
    schema.fields [:text]
    schema.tokenizer :porter
    schema.post_init
    sql = schema.sql_for(:search)
    assert_match(/FROM t\(:term\)/, sql)
    refute_match(/simple_query/, sql)
  end

  def test_extension_missing_raises_named_error
    Litesearch.reset_simple_configuration!
    Litesearch.simple_extension_path = "/nonexistent/libsimple.so"
    if SimpleExtensionHelper.available?
      # Still may find vendor path
      skip "vendored libsimple present"
    end
    db = SQLite3::Database.new(":memory:")
    assert_raises(Litesearch::SimpleExtension::NotFoundError) do
      Litesearch::SimpleExtension.load!(db)
    end
  end
end
