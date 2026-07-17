# Litevector Requirements Specification

**Version:** 0.1  
**Status:** Draft  
**Date:** 2026-07-17  
**Branch:** `litevector`  
**Related:** [GitHub #132](https://github.com/oldmoe/litestack/issues/132), [vectorlite](https://github.com/1yefuwang1/vectorlite)

## Problem Frame

Litestack already provides full-text search (Litesearch / FTS5) but has no first-class **vector / embedding nearest-neighbor** API. Issue #132 asks whether vector search is on the radar and whether SQLite extensions can be loaded through Litedb. Upstream maintainer noted [vectorlite](https://github.com/1yefuwang1/vectorlite) as a candidate but had not evaluated it.

Vector search is a natural fit for Litestack’s “SQLite as the application data plane” philosophy: same process, no network service, path-based storage under `Litesupport.root`. Integrating it as **Litevector** keeps naming and lifecycle consistent with Litecache / Litejob / Litesearch.

**Chosen engine (v1):** [vectorlite](https://github.com/1yefuwang1/vectorlite) — a runtime-loadable SQLite extension that implements HNSW ANN search (via hnswlib) with a SQL virtual-table interface. License: Apache-2.0 (compatible with Litestack MIT).

**Why vectorlite for v1 (vs sqlite-vec):**

| Criterion | vectorlite | sqlite-vec |
|-----------|------------|------------|
| Index | HNSW ANN (scales) | Primarily brute-force (accurate, slower at scale) |
| Speed at N≫1e4 | Strong (ANN) | Linear scan |
| Ruby packaging | No official gem (must vendor/resolve native `.so`) | Official `sqlite-vec` gem |
| Maturity | Beta; possible breaking changes | Pre-v1; broader language bindings |
| Maintainer interest | Explicitly mentioned in #132 | Also mentioned in #132 |

v1 commits to vectorlite as the default backend. The public API MUST allow a future second backend (e.g. sqlite-vec) without changing application call sites where possible.

## Goals

1. Ship a **Litevector** component that can create/update/query approximate nearest neighbors for float32 embeddings stored beside Litestack data.
2. Load the vectorlite native extension into connections used by Litedb / Litevector without requiring a separate database server.
3. Provide Ruby APIs at three levels: raw connection helper, standalone index object, Active Record model DSL (mirroring Litesearch).
4. Keep vector support **optional**: applications that never use Litevector must not pay for native binaries or fail to install.
5. Persist HNSW indexes safely under `Litesupport` paths with explicit save/load (vectorlite keeps the graph in memory per connection).

## Non-Goals (v1)

- Building or reimplementing HNSW in pure Ruby.
- Embedding model inference (OpenAI / local GGUF / etc.) — applications supply float32 vectors.
- Multi-vector columns per index, float16/int8 types, or multi-threaded search inside the extension.
- Guaranteeing 100% recall (ANN is approximate by design).
- Transactional semantics for vector mutations (vectorlite does not support SQLite transactions on the virtual table).
- Replacing Litesearch; hybrid FTS+vector ranking is out of scope for v1 (may be documented as a future composition).
- Vendoring a full C++ build toolchain in CI for every platform on day one (prebuilt binary strategy is acceptable for MVP).

## Constraints From vectorlite

These are hard facts of the engine and MUST shape the API:

| Constraint | Implication for Litevector |
|------------|----------------------------|
| Index is **in-memory per connection** | Must `save` on checkpoint/close and `load` on open; multi-process writers need a single-writer story |
| Explicit **rowid** required on insert; range ≥ 0 | Map application PKs carefully; reject negative ids |
| **float32** only | Normalize Ruby arrays / pack as little-endian float32 BLOB |
| One vector column per virtual table | One embedding field per Litevector index |
| No transactions | Document eventual consistency; no multi-statement atomicity across metadata + HNSW |
| Soft-delete memory | Deletes mark deleted; capacity may need rebuild/compaction strategy later |
| Beta API | Pin a specific vectorlite binary version; integration tests pin that version |
| Metadata filter needs SQLite ≥ 3.38 | Litestack already requires ≥ 3.37 for Litedb; raise floor to ≥ 3.38 when Litevector is enabled |
| Extension load must be enabled | Every connection that uses vectors must `enable_load_extension` + `load_extension` |

## Requirements

### R1 — Optional component

Litevector MUST be loadable via an explicit require path (e.g. `require "litestack/litevector"`) or Rails config flag. The core `require "litestack"` path MUST remain usable without the native extension present.

### R2 — Extension loading

Litevector MUST load vectorlite into a `SQLite3::Database` (including `Litedb`) when:

1. A filesystem path to `vectorlite.so` / `.dylib` / `.dll` is configured, **or**
2. A resolved path from the packaging strategy (see R3) is found.

Loading MUST fail with a named error (`Litevector::ExtensionNotFoundError` / `Litevector::ExtensionLoadError`) that names the attempted path and OS, not a bare `SQLite3::Exception`.

Connections created for Litevector MUST call `enable_load_extension(true)` before load, then ideally re-disable loading after success for hardening.

### R3 — Native binary distribution (v1 strategy)

v1 MUST adopt one of the following packaging strategies (decision locked in plan Task 0 spike):

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A. Sidecar download** | Script/CI downloads vectorlite wheel, extracts `.so` into `vendor/vectorlite/<platform>/` | Controllable versions | Binary size in repo or release assets |
| **B. Runtime path config** | User installs vectorlite themselves; set `LITEVECTOR_EXTENSION_PATH` | Zero shipping | Worse DX |
| **C. Companion gem** | `litevector-native` platform gems | Rubygems-native | Build matrix cost |
| **D. Optional dev gem** | Document `sqlite-vec` gem as temporary alternative only | Existing Ruby gem | Wrong engine for “vectorlite” product |

**Requirement:** Documented install path for Linux x86_64 and at least one of macOS arm64 / x86_64 in CI or manual smoke. Windows is Should Have.

The resolver MUST prefer: explicit config → ENV → vendored platform path → error.

### R4 — Core index API (standalone)

`Litevector::Index` (name TBD, may surface as `Litevector`) MUST support:

| Operation | Behavior |
|-----------|----------|
| `create` / open | Create vectorlite virtual table with dimension, distance (`l2` \| `cosine` \| `ip`), HNSW params (`max_elements`, `ef_construction`, `M`) |
| `upsert(id, vector)` | Insert or replace float32 vector for non-negative integer id |
| `delete(id)` | Delete / soft-delete by id |
| `knn(query, k:, ef:)` | Return array of `{id:, distance:}` (or struct) ordered by engine |
| `count` | Number of active vectors if available; otherwise document limitation |
| `save(path=default)` | Persist HNSW index file via vectorlite `operation='save'` |
| `load(path=default)` | Restore via `operation='load'` |
| `close` | Save if dirty (configurable) and close owned connections |

Default paths MUST live under `Litesupport.root` (e.g. `.../vector/<name>.hnsw` plus optional config sqlite if needed).

### R5 — Vector encoding

Litevector MUST accept:

- `Array` of Numeric → pack to float32 little-endian bytes  
- `String` binary already float32-packed  
- Optional JSON string path for debugging only  

Invalid dimension MUST raise before SQL. NaN/Inf SHOULD be rejected.

### R6 — Litedb integration

`Litedb` SHOULD gain an optional mixin (e.g. `include Litevector::Connection`) that:

- Ensures extension is loaded once per connection  
- Exposes `vector_index(name) { |schema| ... }` analogous to `search_index`  

Primary key linkage: rowid in the vector table equals the application’s integer id by default.

### R7 — Active Record model API (v1.1 target, design in v1)

Mirror Litesearch:

```ruby
class Document < ApplicationRecord
  include Litevector::Model

  litevector do |schema|
    schema.dimensions 1536
    schema.distance :cosine
    schema.max_elements 100_000
    schema.source :embedding   # attribute / method returning Array or binary
  end
end

Document.nearest_neighbors(query_vector, k: 10)
```

Callbacks / after_commit sync of embeddings are **Should Have** for v1; manual `reindex!` is Must Have for v1 if AR ships in the same release.

If AR integration slips, standalone + Litedb APIs alone still satisfy the v1 MVP.

### R8 — Configuration

Support:

```ruby
# ENV
LITEVECTOR_EXTENSION_PATH=/path/to/vectorlite.so
LITESTACK_DATA_PATH=...   # existing; vector files under root

# Ruby
Litevector.configure do |c|
  c.extension_path = "..."
  c.auto_save = true
end

# Rails
config.litestack.vector_extension_path = Rails.root.join("vendor/vectorlite.so")
```

### R9 — Lifecycle & multi-process

- Single-writer assumption for a given index file (document like SQLite writers).  
- After fork, Litevector MUST not reuse a parent connection’s loaded extension state without re-init (align with existing Forkable patterns).  
- `close` MUST be idempotent.  
- Dirty tracking: mutations set dirty; `close` / explicit `checkpoint!` save when `auto_save` is true.

### R10 — Errors

Named errors under `Litevector::`:

- `ExtensionNotFoundError`  
- `ExtensionLoadError`  
- `DimensionMismatchError`  
- `InvalidIdError` (negative / non-integer)  
- `IndexNotOpenError`  
- `PersistenceError` (save/load failure)

### R11 — Tests

| Layer | Requirement |
|-------|-------------|
| Unit | Encoding, path resolution, schema validation — no native ext required |
| Integration | knn insert/search/save/load/reload when extension available |
| Skip policy | If extension missing, integration tests skip with clear message; unit suite still green |
| CI | At least Linux job installs/prepares vectorlite binary and runs integration tests |
| Isolation | Do not redefine global AR models that break other suite files |

Coverage: new Litevector code targets same floors as the rest of the suite (line 80 / branch 50 full suite).

### R12 — Documentation

- README section: what Litevector is / is not  
- Install vectorlite binary steps  
- Standalone example  
- AR example (when available)  
- Limitations table (memory index, ANN recall, no TX, float32)  
- Link to issue #132 and vectorlite upstream  
- Security: extension loading surface; recommend disable after load  

### R13 — Compatibility

- Ruby ≥ 4.0 (Litestack 1.0 baseline)  
- sqlite3 gem ≥ 2.x with `enable_load_extension`  
- SQLite ≥ 3.38 when using rowid filters  
- Rails ≥ 8.1 only for AR adapter path; standalone works without Rails  

### R14 — Observability (Should Have)

Optional Litemetric hooks for knn latency / upsert counts — not blocking MVP.

## Success Criteria

1. With a prepared vectorlite binary on Linux CI, tests demonstrate: create index → insert N vectors → knn returns expected nearest id for a known fixture → save → new connection load → same knn result.  
2. Without the binary, unit tests pass and integration tests skip cleanly; `require "litestack"` does not raise.  
3. Public docs enable a developer to add embeddings to a Rails 8.1 + Litestack app without reading vectorlite C++ sources.  
4. No regression in existing Litesearch / Litedb suite.

## Risks

| Risk | Mitigation |
|------|------------|
| vectorlite beta breaking SQL API | Pin binary version; thin adapter layer around SQL strings |
| No Ruby packaging upstream | Vendor or download script; document version pin |
| In-memory index loss on crash | auto_save + explicit checkpoint; document durability model |
| Multi-process race on save file | Single writer; file lock later if needed |
| Extension load disabled in some SQLite builds | Detect and error clearly; CI uses known-good sqlite3 gem |
| Confusion with sqlite-vec gem | Docs comparison table; backend interface for future |

## Open Questions (resolve in plan Task 0)

1. Exact binary acquisition: vendor in git LFS / release assets / CI cache from PyPI wheel?  
2. Does AR ship in the same MVP milestone or as phase 2 on `litevector` branch?  
3. Should Litevector own a separate SQLite file vs share Litedb’s connection for the virtual table only?  
4. Default distance: `l2` (vectorlite default) vs `cosine` (common for text embeddings)?

## References

- https://github.com/1yefuwang1/vectorlite  
- https://github.com/oldmoe/litestack/issues/132  
- https://github.com/asg017/sqlite-vec (comparison / future backend)  
- https://github.com/nmslib/hnswlib  
- Litestack components: `lib/litestack/litesearch/`, `litedb.rb`, `liteconnection.rb`, `litesupport.rb`
