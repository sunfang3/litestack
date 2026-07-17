# Litevector

Optional **vector / embedding nearest-neighbor** search for Litestack, backed by the [vectorlite](https://github.com/1yefuwang1/vectorlite) SQLite extension (HNSW via hnswlib).

Related: [issue #132](https://github.com/oldmoe/litestack/issues/132), plans under `docs/plans/litevector-*.md`.

## Status

MVP on branch `litevector`. Pinned engine: **vectorlite 0.2.0**.

## Install the native extension

Litevector does **not** ship the `.so` inside the gem. Fetch a platform build:

```bash
bundle exec ruby scripts/fetch_vectorlite.rb
# writes vendor/vectorlite/<platform>/vectorlite.so
```

Or set an explicit path:

```bash
export LITEVECTOR_EXTENSION_PATH=/path/to/vectorlite.so
```

```ruby
# config/application.rb
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
