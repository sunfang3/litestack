# Litevector Spike Notes

**Date:** 2026-07-17  
**vectorlite version:** 0.2.0 (PyPI `vectorlite-py`)  
**Platform:** Linux x86_64 (manylinux2014)

## Binary acquisition

```bash
pip3 download vectorlite-py -d /tmp/vl-wheels --only-binary=:all:
# wheel: vectorlite_py-0.2.0-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
# extract: vectorlite_py/vectorlite.so (~3.4 MB)
# place: vendor/vectorlite/linux-x86_64/vectorlite.so
```

Use `scripts/fetch_vectorlite.rb` for the same flow.

## Load from Ruby (sqlite3 gem 2.9.x)

```ruby
db = SQLite3::Database.new(":memory:")
db.enable_load_extension(true)
db.load_extension("/path/to/vectorlite.so")  # .so suffix works
db.enable_load_extension(false)
db.get_first_value("select vectorlite_info()")
# => "vectorlite extension version 0.2.0, built with SSE"
```

## Persistence API (v0.2.0 — pin this)

**Not** the main-branch `INSERT ... (operation, path)` API. That fails on 0.2.0:

```
table t has no column named operation
```

v0.2.0 uses a **third argument** on `CREATE VIRTUAL TABLE` = index file path:

```sql
CREATE VIRTUAL TABLE t USING vectorlite(
  e float32[3] cosine,
  hnsw(max_elements=100),
  '/abs/path/to/index.bin'
);
```

- On **connection close**, HNSW is written to the index file.  
- On **create** with an existing file, the index is loaded.  
- Dimension must match on reload; `max_elements` may increase.

Path must be a SQL string literal (quoted). Prefer absolute paths.

## Vector bytes

Little-endian float32 works:

```ruby
[1.0, 0.0, 0.0].pack("e*")
```

`vector_from_json('[1,0,0]')` also works for debugging.

## knn query

```sql
SELECT rowid, distance FROM t
 WHERE knn_search(e, knn_param(?, 1));  -- blob, k
-- optional ef as third knn_param arg
```

## ldd deps

Only system libs (`libstdc++`, `libm`, `libpthread`, …). No bundled `.libs` required for manylinux wheel.

## Decisions for implementation

| Topic | Decision |
|-------|----------|
| Pinned version | 0.2.0 |
| Save/load | index file path in CREATE + close to flush |
| Float pack | `"e*"` (little-endian float32) |
| Binary in git | No — fetch script + gitignore `*.so` |
| Explicit checkpoint | Close/reopen connection (or document close-as-save) |
