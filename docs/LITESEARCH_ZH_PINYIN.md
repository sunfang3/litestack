# Litesearch: Chinese and Pinyin

Litestack integrates [wangfenjin/simple](https://github.com/wangfenjin/simple) so FTS5 can index and search **Chinese text** and **Pinyin**.

## Why

Built-in SQLite FTS5 tokenizers (`porter`, `unicode61`, …) do not segment CJK well. The `simple` extension:

- Tokenizes Chinese for substring-style full-text search  
- Indexes Pinyin so queries like `zhonghua` match `中华`  
- Exposes `simple_query()` / `jieba_query()` helpers used by Litesearch search SQL  

## Install the extension

```bash
bundle exec ruby scripts/fetch_simple.rb
# → vendor/simple/<platform>/libsimple.so (+ dict/ for jieba)
```

Or set:

```bash
export LITESEARCH_SIMPLE_EXTENSION_PATH=/path/to/libsimple.so
```

```ruby
Litesearch.simple_extension_path = "/path/to/libsimple.so"
```

## Usage

```ruby
require "litestack/litedb"

db = Litedb.new("db/search.sqlite3")
idx = db.search_index(:articles) do |schema|
  schema.fields [:title, :body]
  schema.tokenizer :simple          # requires libsimple
  # schema.query_builder :jieba     # optional; needs dict/ beside .so
  # schema.query_builder :raw       # pass FTS5 syntax yourself
end

idx.add(rowid: 1, title: "国歌", body: "中华人民共和国国歌")
idx.search("中华国歌")   # Chinese
idx.search("zhonghua")   # Pinyin
```

### ActiveRecord

```ruby
class Article < ApplicationRecord
  include Litesearch::Model

  litesearch do |schema|
    schema.fields [:title, :body]
    schema.tokenizer :simple
  end
end

Article.search("中华国歌")
Article.search("beijing")
```

Litesearch rewrites `MATCH` to `MATCH simple_query(?)` when the schema uses `tokenizer :simple` (or `jieba_query(?)` when `query_builder :jieba`).

## Tokenizers comparison

| Schema | Extension | Query helper | Notes |
|--------|-----------|--------------|-------|
| `:porter` (default) | none | raw term | English-oriented stemming |
| `:unicode` | none | raw term | Unicode61 |
| `:trigram` | none | raw term | Substring via trigrams |
| `:simple` | libsimple | `simple_query` / `jieba_query` | Chinese + Pinyin |

## Limitations

- Optional native dependency — without `libsimple`, creating a `:simple` index raises a named error.  
- Changing tokenizer on an existing index requires rebuild (`rebuild_on_modify` / drop + recreate).  
- First pinyin use may load an internal dict (~500ms per simple’s docs).  
- Jieba dict load is heavier (~seconds); only needed for `query_builder :jieba`.  

## Tests

```bash
bundle exec ruby scripts/fetch_simple.rb
COVERAGE_PARTIAL=1 bundle exec ruby -Ilib:test -r./test/helper \
  -e 'require "./test/test_litesearch_simple_zh_pinyin"'
```

Without the binary, integration cases skip; SQL registration unit tests still run where they do not need the extension.
