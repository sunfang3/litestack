# LiteCache L1 + Honker Invalidation — Design Review

**Status:** review + benchmark baseline (implementation gated)  
**Date:** 2026-07-22  
**Related:** `docs/Integration_with_Honker.md` §九.4

---

## 1. Current LiteCache shape

| Concern | Today |
|--------|--------|
| Storage | Single SQLite file (`cache.sqlite3`), table `data` |
| API | `get` / `set` / `set_multi` / `get_multi` / `delete` / `clear` / `increment` |
| Expiry | SQL `expires_in` + background pruner thread |
| Process model | Each process opens its own connection; **no process-local hot cache** |
| Rails | `ActiveSupport::Cache::Litecache` → `::Litecache` |

Every `get` is a SQLite prepared statement. That is already competitive with Redis for small values (see `BENCHMARKS.md`), but multi-process apps still pay SQL + possible `busy` on every hit.

The design doc proposes an **L1 process-local cache** in front of SQLite, with **Honker notify** to invalidate other processes:

```text
cache:set:key | cache:delete:key | cache:clear
```

---

## 2. Goals

1. **Cut hot-path read latency** for keys that are repeatedly read in the same process (L1 hit).
2. **Keep multi-process coherence** without re-introducing Redis: after `set`/`delete`/`clear` in process A, process B must not serve a stale L1 value forever.
3. **No regression** on the current single-layer path when L1 is off (default).
4. **Measurable**: broadcast latency, L1 hit rate, write amplification — gated by benchmarks before merge.

---

## 3. Design review (risks & decisions)

### 3.1 Channel / payload model — **revise the design-doc sketch**

The sketch `cache:set:key` as a **channel name per key** is a bad default:

| Approach | Pros | Cons |
|----------|------|------|
| Channel = full key (`cache:set:user:42`) | Fine-grained listen | Unbounded channel cardinality; Listener API is per-channel; prune noise |
| Single channel `litecache` + payload `{op, key, …}` | One listener; batchable | All writers wake all L1s (filter in-process) |
| Prefix channels (`litecache:shard:N`) | Cap fanout | Extra config |

**Recommendation:** one (or few) channel(s):

```json
// notify("litecache", payload)
{"op":"set","key":"a","gen":17,"src":"<instance_id>"}
{"op":"delete","key":"a","src":"..."}
{"op":"clear","src":"..."}
{"op":"mset","keys":["a","b"],"src":"..."}
```

- **`src`**: skip self-invalidation (writer already updated L1).
- **`gen` (optional)**: monotonic write generation for the key; L1 entry stores `gen` and ignores stale late notifications.
- **Do not notify on every L1-only touch** — only on durable L2 mutations.

### 3.2 Coherence model — **eventual, not linearizable**

SQLite L2 remains the source of truth. L1 is a **performance cache** with:

```text
write path:  update L2 → update local L1 → notify (same txn as notify if Honker on L2 file)
read path:   L1 hit? return : L2 get → fill L1
on notify:   drop L1 key(s) (or mark generation stale)
```

**Race accepted:** process B may serve one stale L1 read between A’s L2 commit and B’s invalidate. Same class as Memcached/Redis without CAS. Document it; do **not** claim strong consistency.

**Mitigations (optional later):** short L1 TTL (e.g. 1–5s) as a backstop if notify is lost; `gen` checks on fill.

### 3.3 Where does Honker live?

| Option | Notes |
|--------|--------|
| **A. Same file as LiteCache** | `notify` in same COMMIT as `INSERT INTO data` → true outbox for invalidation. **Preferred.** |
| **B. Separate notify.sqlite3** | Dual-write again; avoid. |
| **C. No Honker, L1 only + TTL** | Single-process win; multi-process stale until TTL. OK as `l1_coherence: ttl`. |

**Recommendation:** L1 + Honker only when path is file-backed and `honker` gem loads; otherwise L1+TTL or L1 disabled.

Loading Honker extension on the Litecache write connection is required for transactional `notify()`. Watcher/listener uses a second connection (same as LiteCable).

### 3.4 Write amplification — **main regression risk**

Today: `set` = 1 SQLite write.  
With naive notify: `set` = 1 write + `notify` insert + watcher traffic on **every** writer and **every** process.

Risks:

- High-churn caches (session write-per-request) become notify-bound.
- Multi-writer: each set wakes all processes even if they never held the key.

**Controls (must ship with feature flags):**

| Flag | Default | Effect |
|------|---------|--------|
| `l1: false` | **false** | Zero change vs today |
| `l1_max_entries` | e.g. 10_000 | Bound memory (LRU) |
| `invalidate: :none \| :ttl \| :honker` | `:none` | Coherence mode |
| `notify_on: [:delete, :clear]` first | progressive | Phase 1: only invalidate on delete/clear; set relies on L1 overwrite locally + optional TTL for others |
| `notify_batch_ms` | 0–5 | Coalesce mset into one notify |

**Phase recommendation:**

1. **L1 only, same-process** (`invalidate: :none`) — pure read win; no multi-process claims.  
2. **TTL backstop** (`invalidate: :ttl`) — multi-process eventual.  
3. **Honker notify** (`invalidate: :honker`) — measure write IPS and invalidate p99 before defaulting.

### 3.5 What NOT to put in L1

- **`increment` / `decrement`**: stay L2-only (or treat as delete-from-L1 after L2). Racey if L1 caches integers across processes.
- **Huge values**: skip L1 above `l1_max_value_bytes` (e.g. 64KB) so L1 stays CPU-cache friendly.
- **`:memory:` SQLite path**: no cross-process Honker; L1 still OK for single process.

### 3.6 Fork / Puma workers

Reuse Litestack patterns:

- Fork: drop L1, close Honker listener, `setup` again.
- Do not inherit parent L1 (stale + wrong generation).
- One invalidation listener per process (not per request).

### 3.7 ActiveSupport::Cache::Litecache

Rails store already serializes entries. L1 should sit **inside** `::Litecache` (string payload), not in the AS adapter, so raw and Rails paths share one mechanism.

---

## 4. Recommended architecture (target)

```text
                    ┌──────────────────────────┐
   get/set/delete   │  Litecache API           │
                    └───────────┬──────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
        ┌──────────┐     ┌──────────┐      ┌────────────┐
        │ L1 Hash  │     │ L2 SQLite│      │ Invalidator│
        │ + LRU    │◄───►│  data    │─────►│ Honker nfy │
        └──────────┘     └──────────┘      └─────┬──────┘
              ▲                                  │
              │         other processes          │
              └──────── listener invalidate ─────┘
```

**APIs (internal):**

```ruby
Litecache.new(
  l1: true,
  l1_max_entries: 10_000,
  l1_max_value_bytes: 65_536,
  l1_ttl: 5,                 # soft TTL; 0 = only explicit invalidate
  invalidate: :honker,       # :none | :ttl | :honker
  notify_ops: %i[set delete clear],
  watcher_poll_interval_ms: 5
)
```

---

## 5. Success metrics (must measure before enabling defaults)

| Metric | Definition | Gate (initial) |
|--------|------------|----------------|
| **L2 get IPS** | get on warm cache, L1 off | ≥ 95% of baseline captured in CI/local bench |
| **L2 set IPS** | set, L1 off | ≥ 95% of baseline |
| **L1 get IPS** | get after warm L1 | ≥ 3× L2 get (same machine) aspirational |
| **L1 hit rate** | hits / (hits+misses) under read-heavy mix | reported, scenario-dependent |
| **Write tax** | set IPS with notify vs without | ≥ 80% of no-notify (or document cost) |
| **Invalidate p50/p99** | time from writer set commit → peer L1 miss | p99 &lt; 50ms local SSD target |
| **Stale window** | max observed stale reads under load | report only |

Baselines are produced by `bench/bench_litecache_l1.rb` and stored under `bench/results/`.

---

## 6. Benchmark plan (early, regression-first)

Script: **`bench/bench_litecache_l1.rb`**

Modes:

1. **`baseline`** — current Litecache only (L1 forced off). Establishes regression floor.
2. **`l1_local`** — L1 on, no Honker (when implemented); measures read win + write fill cost.
3. **`invalidate`** — two processes, writer mutates, reader polls L1 coherence latency (Honker path).
4. **`compare`** — load previous JSON baseline; fail process exit 2 if L2 path regresses &gt; threshold.

CI policy (recommended):

- PR must run `baseline` (or `compare`) on Linux x86_64.
- L1/honker modes optional until feature lands; never change default `l1: false` without green compare.

---

## 7. Implementation order (gated)

| Step | Work | Exit criteria |
|------|------|----------------|
| 0 | Design review + baseline bench (this doc + script) | ✅ |
| 1 | L1 module + hooks, default off | ✅ `lib/litestack/litecache/l1.rb`; `compare` gate |
| 2 | L1 fill on get/set; LRU + size skip + soft TTL | ✅ `l1: true` opt-in; `l1_local` bench |
| 3 | Soft TTL as multi-process backstop (`invalidate: :ttl`) | next |
| 4 | Honker transactional notify + listener | next |
| 5 | Rails adapter smoke + multi-process soak | later |

**Do not** flip `l1: true` by default until step 4 gates pass.

---

## 8. Review verdict

| Item | Verdict |
|------|---------|
| L1 in front of SQLite LiteCache | **Sound** for read-heavy same-process workloads |
| Honker for cross-process invalidate | **Sound** if same-file transactional notify + single channel |
| Per-key channel names | **Reject** as default |
| Notify on every set by default | **Defer** until write-tax measured |
| Ship without benchmarks | **Reject** |
| Default-on L1 | **Reject** until compare gates pass |

**Overall:** proceed with **benchmark-first, feature-flagged L1**, Honker invalidation as a later opt-in coherence backend — not a rewrite of LiteCache.

---

## 9. Open questions for product

1. Target deploy: single Puma process vs many workers? (drives how soon Honker invalidate is needed)
2. Acceptable stale window (ms)?  
3. Prefer memory cap (entries) vs byte cap?  
4. Should Rails `MemoryStore`-style L1 be per-request or process-global? (**process-global** recommended.)
