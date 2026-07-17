# Litevector Implementation Plan

> **For agentic workers:** Implement task-by-task on branch `litevector`. Prefer TDD. Keep vector support optional. Do not break the existing suite when the native extension is absent.

**Goal:** Integrate [vectorlite](https://github.com/1yefuwang1/vectorlite) into Litestack as an optional **Litevector** component for in-process HNSW vector search.

**Architecture:** Thin Ruby facade over a runtime-loaded SQLite extension. Path resolver finds a platform binary; `Litevector::Extension` loads it once per connection; `Litevector::Index` owns virtual-table DDL, float32 packing, knn SQL, and HNSW save/load under `Litesupport.root`. Optional Litedb mixin and later Active Record DSL mirror Litesearch patterns.

**Tech Stack:** Ruby 4+, sqlite3 gem 2.x (`enable_load_extension` / `load_extension`), vectorlite native `.so|.dylib|.dll` (Apache-2.0), Minitest, existing Litestack `Litesupport` / Railtie.

**Spec:** `docs/plans/litevector-requirements.md`  
**Branch:** `litevector` (tracks this work; base is current `issue-fixes` / mainline modernization)  
**Upstream issue:** [#132](https://github.com/oldmoe/litestack/issues/132)

---

## File map (target)

| Path | Responsibility |
|------|----------------|
| `lib/litestack/litevector.rb` | Public require entry; configure API |
| `lib/litestack/litevector/errors.rb` | Named errors |
| `lib/litestack/litevector/extension.rb` | Resolve path + load into `SQLite3::Database` |
| `lib/litestack/litevector/vector.rb` | float32 pack/unpack, dimension checks |
| `lib/litestack/litevector/schema.rb` | Index definition (dim, distance, HNSW params) |
| `lib/litestack/litevector/index.rb` | Create/open, upsert, delete, knn, save/load, close |
| `lib/litestack/litevector/connection.rb` | Mixin for Litedb / raw DB |
| `lib/litestack/litevector/model.rb` | Active Record DSL (phase 2) |
| `lib/litestack/railtie.rb` | Optional `config.litestack.vector_extension_path` |
| `lib/litestack.rb` or component list | Soft documentation only — do **not** auto-require Litevector in core boot |
| `scripts/fetch_vectorlite.rb` | Download/extract prebuilt binary for platform |
| `vendor/vectorlite/.gitkeep` + README | Binary placement (binaries gitignored unless release policy says otherwise) |
| `test/test_litevector_vector.rb` | Encoding unit tests (no ext) |
| `test/test_litevector_extension.rb` | Path resolution / skip-if-missing |
| `test/test_litevector_index.rb` | Integration knn/save/load (skip without ext) |
| `test/support/vectorlite_helper.rb` | `vectorlite_available?`, fixture vectors |
| `docs/LITEVECTOR.md` | User guide |
| `.gitignore` | Ignore `vendor/vectorlite/**/*.{so,dylib,dll}` if not vendored in git |

---

## Design decisions (locked unless Task 0 overturns)

1. **Engine:** vectorlite only for v1 SQL dialect.  
2. **Optional:** `require "litestack/litevector"` — never hard-fail core gem install.  
3. **Owned connection default:** Index may use its own `SQLite3::Database` file under `Litesupport.root.join("vector/#{name}.sqlite3")` for the virtual table + a sibling `#{name}.hnsw` for the HNSW dump. Sharing an application Litedb connection is supported via mixin but not required for MVP.  
4. **Default distance:** `cosine` for text-embedding ergonomics; schema can set `l2`.  
5. **IDs:** Integer ≥ 0 only; AR integer PKs map 1:1 to vectorlite rowid.  
6. **Dirty + auto_save:** default true on close.  
7. **AR model:** Phase 2 on the same branch after standalone is green.

---

### Task 0: Spike — load vectorlite from Ruby

**Files:**
- Create: `scripts/fetch_vectorlite.rb` (minimal)
- Create: `tmp/vectorlite_spike.rb` (disposable)

- [ ] **Step 1: Confirm extension load on this machine**

```bash
bundle exec ruby -e 'require "sqlite3"; db=SQLite3::Database.new(":memory:"); db.enable_load_extension(true); puts :ok'
```

Expected: prints `ok` (already verified on sqlite3 2.9.x / SQLite 3.53).

- [ ] **Step 2: Obtain a Linux x86_64 `vectorlite.so`**

Preferred approach for spike:

```bash
# Example — adjust to current PyPI wheel layout for vectorlite-py
pip download vectorlite-py -d /tmp/vl-wheels --only-binary=:all:
# wheel is a zip; extract vectorlite*.so
unzip -l /tmp/vl-wheels/vectorlite_py-*.whl | head
```

Document the exact wheel version and extracted path in `docs/plans/litevector-spike-notes.md`.

- [ ] **Step 3: Run minimal knn SQL from Ruby**

```ruby
require "sqlite3"
path = ENV.fetch("LITEVECTOR_EXTENSION_PATH")
db = SQLite3::Database.new(":memory:")
db.enable_load_extension(true)
db.load_extension(path)
db.enable_load_extension(false)
p db.get_first_value("select vectorlite_info()")
db.execute("create virtual table t using vectorlite(e float32[3], hnsw(max_elements=10))")
# pack float32 or use vector_from_json
db.execute("insert into t(rowid, e) values (0, vector_from_json('[1,0,0]'))")
db.execute("insert into t(rowid, e) values (1, vector_from_json('[0,1,0]'))")
rows = db.execute("select rowid, distance from t where knn_search(e, knn_param(vector_from_json('[0.9,0.1,0]'), 1))")
p rows
```

Expected: nearest rowid `0`.

- [ ] **Step 4: Record spike outcomes**

Write `docs/plans/litevector-spike-notes.md` with: binary source, version, load quirks, save/load path commands, any sqlite3 gem caveats.

- [ ] **Step 5: Commit notes + fetch script skeleton**

```bash
git add scripts/fetch_vectorlite.rb docs/plans/litevector-spike-notes.md
git commit -m "chore(litevector): spike notes for vectorlite extension load"
```

---

### Task 1: Errors + vector encoding (no native)

**Files:**
- Create: `lib/litestack/litevector/errors.rb`
- Create: `lib/litestack/litevector/vector.rb`
- Create: `lib/litestack/litevector.rb` (requires errors + vector only at first)
- Create: `test/test_litevector_vector.rb`

- [ ] **Step 1: Failing tests for pack/unpack**

```ruby
# test/test_litevector_vector.rb
require_relative "helper"
require "litestack/litevector"

class TestLitevectorVector < Minitest::Test
  def test_pack_array_float32_le
    bin = Litevector::Vector.pack([1.0, 2.0, 3.0])
    assert_equal 12, bin.bytesize
    assert_equal [1.0, 2.0, 3.0], Litevector::Vector.unpack(bin)
  end

  def test_dimension_mismatch
    assert_raises(Litevector::DimensionMismatchError) do
      Litevector::Vector.pack([1.0, 2.0], dimensions: 3)
    end
  end

  def test_reject_nan
    assert_raises(ArgumentError) { Litevector::Vector.pack([Float::NAN]) }
  end
end
```

- [ ] **Step 2: Implement `Litevector::Vector` and errors**

Use `array.pack("e*")` / `unpack("e*")` for little-endian float32 (verify against vectorlite on spike machine; switch to `"f*"` native endian only if spike proves need).

- [ ] **Step 3: Run tests**

```bash
COVERAGE_PARTIAL=1 bundle exec ruby -Ilib:test -r./test/helper -e 'require "./test/test_litevector_vector"'
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(litevector): float32 vector packing and errors"
```

---

### Task 2: Extension path resolution + load

**Files:**
- Create: `lib/litestack/litevector/extension.rb`
- Create: `test/test_litevector_extension.rb`
- Create: `test/support/vectorlite_helper.rb`
- Modify: `lib/litestack/litevector.rb`

- [ ] **Step 1: Resolver behavior tests (no file required)**

```ruby
def test_resolve_prefers_explicit
  Litevector.configure { |c| c.extension_path = "/tmp/custom.so" }
  assert_equal "/tmp/custom.so", Litevector::Extension.resolve_path
ensure
  Litevector.reset_configuration!
end

def test_missing_raises_named_error
  Litevector.reset_configuration!
  ENV.delete("LITEVECTOR_EXTENSION_PATH")
  # stub vendored paths empty
  assert_raises(Litevector::ExtensionNotFoundError) do
    Litevector::Extension.load!(SQLite3::Database.new(":memory:"))
  end
end
```

- [ ] **Step 2: Implement configure + resolve + load!**

```ruby
module Litevector
  class << self
    attr_accessor :extension_path, :auto_save
    def configure; yield self; end
    def reset_configuration!; @extension_path = nil; @auto_save = true; end
  end

  module Extension
    module_function
    def resolve_path
      candidates = [
        Litevector.extension_path,
        ENV["LITEVECTOR_EXTENSION_PATH"],
        vendored_path
      ].compact.map(&:to_s).reject(&:empty?)
      found = candidates.find { |p| File.file?(p) }
      found || raise(ExtensionNotFoundError, "vectorlite binary not found; tried: #{candidates.inspect}")
    end

    def load!(db)
      path = resolve_path
      db.enable_load_extension(true)
      db.load_extension(path)
      db.enable_load_extension(false)
      path
    rescue ExtensionNotFoundError
      raise
    rescue => e
      raise ExtensionLoadError, "failed to load #{path}: #{e.class}: #{e.message}"
    end
  end
end
```

- [ ] **Step 3: Integration load when available**

```ruby
def test_load_when_binary_present
  skip "no vectorlite" unless VectorliteHelper.available?
  db = SQLite3::Database.new(":memory:")
  Litevector::Extension.load!(db)
  info = db.get_first_value("select vectorlite_info()")
  refute_nil info
end
```

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(litevector): extension path resolution and load"
```

---

### Task 3: Schema + Index CRUD / knn

**Files:**
- Create: `lib/litestack/litevector/schema.rb`
- Create: `lib/litestack/litevector/index.rb`
- Create: `test/test_litevector_index.rb`
- Modify: `lib/litestack/litevector.rb`

- [ ] **Step 1: Write integration tests (skip without ext)**

```ruby
def setup
  skip "vectorlite extension not available" unless VectorliteHelper.available?
  @dir = Dir.mktmpdir
  Litesupport.data_path = @dir
  @index = Litevector::Index.create(
    name: "docs",
    dimensions: 3,
    distance: :cosine,
    max_elements: 100
  )
end

def test_knn_returns_nearest
  @index.upsert(0, [1.0, 0.0, 0.0])
  @index.upsert(1, [0.0, 1.0, 0.0])
  hits = @index.knn([0.9, 0.1, 0.0], k: 1)
  assert_equal 0, hits.first[:id]
end

def test_save_and_reload
  @index.upsert(0, [1.0, 0.0, 0.0])
  @index.checkpoint!
  @index.close
  reopened = Litevector::Index.open(name: "docs", dimensions: 3, distance: :cosine, max_elements: 100)
  hits = reopened.knn([1.0, 0.0, 0.0], k: 1)
  assert_equal 0, hits.first[:id]
ensure
  reopened&.close
end
```

- [ ] **Step 2: Implement Index**

Key SQL patterns (from vectorlite README):

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS lv_docs
  USING vectorlite(embedding float32[3] cosine, hnsw(max_elements=100));

INSERT INTO lv_docs(rowid, embedding) VALUES (?, ?);
-- or vector_from_json for debug

SELECT rowid, distance FROM lv_docs
 WHERE knn_search(embedding, knn_param(?, ?, ?));  -- blob, k, ef

INSERT INTO lv_docs(operation, path) VALUES ('save', ?);
INSERT INTO lv_docs(operation, path) VALUES ('load', ?);
```

Implementation notes:

- Store config JSON in a small sidecar table or `#{name}.yml` under vector root for reopen without caller re-passing HNSW params when possible.  
- Virtual table name: sanitize `lv_<name>`.  
- On `create_connection`, load extension before DDL.  
- Track `@dirty` on upsert/delete.

- [ ] **Step 3: Green tests + commit**

```bash
git commit -am "feat(litevector): Index create upsert knn save load"
```

---

### Task 4: Litedb connection mixin

**Files:**
- Create: `lib/litestack/litevector/connection.rb`
- Create: `test/test_litevector_connection.rb`
- Optional modify: `lib/litestack/litedb.rb` — **do not** auto-include; document `Litedb.include Litevector::Connection` or explicit require that extends.

- [ ] **Step 1: API**

```ruby
db = Litedb.new(":memory:")
db.extend(Litevector::Connection) # or include at class level when required
db.ensure_vectorlite!
idx = db.vector_index(:items) do |s|
  s.dimensions 8
  s.distance :l2
  s.max_elements 1000
end
```

Prefer **explicit** opt-in so Litedb does not require the binary.

- [ ] **Step 2: Tests + commit**

```bash
git commit -am "feat(litevector): optional Litedb connection mixin"
```

---

### Task 5: Railtie config + fetch script polish

**Files:**
- Modify: `lib/litestack/railtie.rb` — `config.litestack.vector_extension_path`
- Modify: `scripts/fetch_vectorlite.rb` — production-quality download for CI
- Create: `docs/LITEVECTOR.md`
- Modify: `README.md` — short pointer section
- Modify: `.gitignore`

- [ ] **Step 1: Railtie**

```ruby
config.litestack.vector_extension_path = nil
initializer "litestack.configure_vector", after: "litestack.configure_data_path" do |app|
  path = app.config.litestack.vector_extension_path
  if path && !path.to_s.empty?
    require "litestack/litevector"
    Litevector.extension_path = path.to_s
  end
end
```

- [ ] **Step 2: CI note**

Add a non-blocking or optional job step later:

```yaml
- run: bundle exec ruby scripts/fetch_vectorlite.rb
- run: bundle exec rake test TEST=test/test_litevector_index.rb
  env:
    LITEVECTOR_EXTENSION_PATH: vendor/vectorlite/linux-x86_64/vectorlite.so
```

(Defer full CI matrix wiring until binary story is stable.)

- [ ] **Step 3: Commit**

```bash
git commit -am "docs(litevector): user guide, railtie path, fetch script"
```

---

### Task 6: Active Record model (phase 2)

**Files:**
- Create: `lib/litestack/litevector/model.rb`
- Create: `test/test_litevector_ar_model.rb` (namespaced models — no global `Book`)

- [ ] **Step 1: DSL + nearest_neighbors**

```ruby
module Litevector::Model
  def self.included(base)
    base.extend(ClassMethods)
  end
  module ClassMethods
    def litevector(&block)
      # build schema, open index under Litesupport.root
    end
    def nearest_neighbors(vector, k: 10, ef: nil)
      ids = litevector_index.knn(vector, k: k, ef: ef).map { |h| h[:id] }
      # preserve order via CASE or in-Ruby sort
      where(id: ids) # then reorder
    end
  end
end
```

- [ ] **Step 2: Manual reindex**

```ruby
def reindex_vector!
  self.class.litevector_index.upsert(id, send(embedding_source))
end
```

after_commit sync is optional follow-up.

- [ ] **Step 3: Tests with namespaced AR models + commit**

```bash
git commit -am "feat(litevector): ActiveRecord nearest_neighbors DSL"
```

---

### Task 7: Hardening + suite gate

- [ ] Full `bundle exec rake test` green with and without extension (skips).  
- [ ] StandardRB clean on new files.  
- [ ] Coverage floors held.  
- [ ] Update `docs/plans/litevector-requirements.md` status fields if decisions changed.  
- [ ] Final commit: `chore(litevector): mvp complete on branch`

```bash
git commit --allow-empty -m "chore(litevector): mark MVP checklist complete"
```

---

## Implementation order summary

```
Task 0  Spike binary + SQL from Ruby
Task 1  Vector packing (unit)
Task 2  Extension load (unit + optional integration)
Task 3  Index knn/save/load (integration)
Task 4  Litedb mixin
Task 5  Docs / railtie / fetch script
Task 6  AR model (phase 2)
Task 7  Hardening
```

## Out of scope on this branch (later)

- Hybrid FTS + vector ranking  
- sqlite-vec backend adapter  
- Multi-process file locking beyond documentation  
- Windows CI  
- Publishing `litevector-native` platform gems  

## Execution handoff

After this plan is accepted:

1. Stay on branch `litevector`.  
2. Start **Task 0** spike (binary acquisition is the critical path).  
3. Prefer small commits per task as above.  
4. Do not merge to `master` until MVP Task 3+ is green and docs exist.

**Commands to begin:**

```bash
git checkout litevector
# Task 0
bundle exec ruby -e 'require "sqlite3"; ...'
# then implement scripts/fetch_vectorlite.rb
```
