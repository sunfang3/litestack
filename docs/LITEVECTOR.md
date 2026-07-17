# Litevector

Optional **vector / embedding nearest-neighbor** search for Litestack, backed by the [vectorlite](https://github.com/1yefuwang1/vectorlite) SQLite extension (HNSW via hnswlib).

Related: [issue #132](https://github.com/oldmoe/litestack/issues/132), plans under `docs/plans/litevector-*.md`.

## Status

Pinned engine: **vectorlite 0.2.0**. Optional — core Litestack works without it.

**Rails full-stack install (recommended path):** [RAILS_FULL_STACK.md](RAILS_FULL_STACK.md)

## Install the native extension

Litevector does **not** ship the `.so` inside the gem. Fetch a platform build.

**In a Rails app** (put binaries under the app, not the gem):

```bash
export LITESTACK_EXTENSION_ROOT="$PWD"
bundle exec ruby "$(bundle show litestack)/scripts/fetch_vectorlite.rb"
# → vendor/vectorlite/<platform>/vectorlite.so
```

**In the litestack repo** (gem development):

```bash
bundle exec ruby scripts/fetch_vectorlite.rb
```

Wire path (Rails initializer or ENV):

```bash
export LITEVECTOR_EXTENSION_PATH=/path/to/vectorlite.so
```

```ruby
# config/initializers/litestack_extensions.rb (created by litestack:install)
config.litestack.vector_extension_path = Rails.root.join(
  "vendor/vectorlite/linux-x86_64/vectorlite.so"
)
```

## Quick start (standalone)

```ruby
require "litestack/litevector"

Litevector.extension_path = "vendor/vectorlite/linux-x86_64/vectorlite.so"

index = Litevector::Index.create(
  name: "docs",
  dimensions: 1536,
  distance: :cosine,   # :l2, :cosine, :ip
  max_elements: 100_000
)

index.upsert(1, embedding_array)  # Array of Float, length == dimensions
hits = index.knn(query_array, k: 10, ef: 50)
# => [{id: 1, distance: 0.02}, ...]

index.checkpoint!  # flush HNSW to disk (close+reopen connection)
index.close        # also flushes (vectorlite saves on connection close)

# later
index = Litevector::Index.open(name: "docs")
```

Files (under `Litesupport.root` / `LITESTACK_DATA_PATH`):

- `vector/<name>.hnsw` — HNSW graph  
- `vector/<name>.json` — schema metadata  

## Litedb mixin

```ruby
db = Litedb.new(":memory:")
db.extend(Litevector::Connection)
db.ensure_vectorlite!
puts db.vectorlite_info
```

## Active Record

```ruby
class Document < ApplicationRecord
  include Litevector::Model

  litevector do |schema|
    schema.dimensions 1536
    schema.distance :cosine
    schema.max_elements 100_000
    schema.source :embedding   # method returning Array or float32 binary
  end
end

doc = Document.create!(...)
doc.reindex_vector!
Document.nearest_neighbors(query, k: 10)  # ordered; each has #vector_distance
```

## Limitations (engine)

| Topic | Behavior |
|-------|----------|
| Accuracy | Approximate (HNSW), not 100% recall |
| Vector type | float32 only |
| IDs | integer rowid ≥ 0 |
| Transactions | not supported on the virtual table |
| Memory | HNSW lives in process memory; durable via index file on close |
| DROP TABLE | deletes the index file (v0.2.0) |

## Tests

```bash
bundle exec ruby scripts/fetch_vectorlite.rb
COVERAGE_PARTIAL=1 bundle exec ruby -Ilib:test -r./test/helper \
  -e 'require "./test/test_litevector_vector"; require "./test/test_litevector_index"'
```

Without the binary, unit tests still pass; integration tests skip.
