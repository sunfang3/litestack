# Honker integration (optional)

[Honker](https://honker.dev) is an **optional** peer gem. Litestack soft-requires it:
without Honker, components keep **polling / destructive** defaults and still work.

With Honker you get lower idle wake latency, claim/ack jobs, L1 cache invalidate,
and a durable job lifecycle stream for LiteBoard.

Design background: [Integration_with_Honker.md](Integration_with_Honker.md) ·
LiteCache L1: [plans/litecache-l1-honker-design-review.md](plans/litecache-l1-honker-design-review.md).

---

## Install in a Rails (or plain Ruby) app

Honker **0.4.0** for this fork is published on **GitHub Packages** (`sunfang3`),
not RubyGems.org.

### 1. Authenticate Bundler to GitHub Packages

Create a classic PAT with at least `read:packages` (and `repo` if the package is private).

```bash
# username is your GitHub login; password is the PAT
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="YOUR_GH_USERNAME:YOUR_PAT"

# or permanent local/global config:
bundle config set --local rubygems.pkg.github.com "YOUR_GH_USERNAME:YOUR_PAT"
```

CI: store the same `username:PAT` string as repository secret
`BUNDLE_RUBYGEMS__PKG__GITHUB__COM` (Actions workflow injects it into
`env` for every job). Workflow also requests `packages: read` so
`GITHUB_TOKEN` can be used as a fallback for packages owned by the same
account when the dedicated secret is absent.

### 2. Gemfile

```ruby
# Gemfile
source "https://rubygems.org"

gem "litestack"
# …

source "https://rubygems.pkg.github.com/sunfang3" do
  gem "honker", "0.4.0"
end
```

```bash
bundle install
```

Litestack itself does **not** hard-depend on Honker at gem install time; apps that
want the optional features add the block above.

---

## Capability matrix

| Area | Option(s) | Without Honker | With Honker |
|------|-----------|----------------|-------------|
| **LiteJob wake** | `wakeup: :honker` | Sleep-interval polling | `data_version` / notify wake + deadline-aware wait |
| **LiteJob notify filter** | `queue_notify`, `wakeup_filter_notifications` | Every commit can thrash workers | Enqueue-oriented channels only |
| **LiteJob reliability** | `backend: :honker` | Destructive `pop` (at-most-once if kill -9) | claim / ack / visibility timeout + **heartbeat** during long `perform` |
| **LiteJob outbox** | `database: :primary`, `outbox: true` | Separate queue file (dual-write) | Same SQLite file; auto `table_prefix: litestack_` → **`litestack_queue`**; enqueue on AR connection; no `user_version` fight with the app |

### Long jobs (claim heartbeat)

```yaml
production:
  backend: honker
  visibility_timeout: 300   # claim lease seconds
  heartbeat_interval: 60    # extend while perform runs; 0 = off
  # heartbeat_extend: 300   # optional; default = visibility_timeout
```

Without heartbeat, a `perform` longer than `visibility_timeout` can be reclaimed
by another worker (at-least-once duplicate). Heartbeat renews the lease until
ack/retry.

### Outbox / primary co-location

```yaml
# config/litejob.yml
production:
  database: primary   # path = Rails primary SQLite file
  outbox: true        # default when database: primary
  # table_prefix: litestack_   # default on primary → table litestack_queue
  # table_prefix: ""           # bare "queue" (only if you accept name clash risk)
```

```ruby
Order.transaction do
  order = Order.create!(...)
  ReportJob.perform_later(order.id)  # same COMMIT as order
end
```
| **LiteJob leadership** | `leadership: true` (default when path ok) | Every process may run GC | Named lock: one GC leader |
| **LiteJob results** | `job_results: true` | Table still works without Honker | Same; stream optional |
| **LiteJob lifecycle** | `lifecycle_stream: true` | No stream | Honker stream → LiteBoard feed |
| **LiteCable** | `transport: :honker` | ~50ms message-table poll | notify / listen across processes |
| **LiteCable pruner** | `leadership: true` | Every process may prune | Named lock leader |
| **LiteCache L1** | `l1: true` | Off by default | Process-local LRU |
| **LiteCache coherence** | `invalidate: :ttl \| :honker` | `:none` | Soft TTL and/or peer L1 drop via notify |

**Defaults stay conservative:** no L1, `invalidate: :none`, `wakeup: :polling`,
`transport: :polling`, `backend: :litequeue` unless you opt in.

---

## Config samples (in-repo)

| File | Purpose |
|------|---------|
| `samples/litejob.honker.yml` | Job wakeup / backend / outbox / lifecycle |
| `samples/litecable.honker.yml` | Cable transport |
| `samples/litecache.honker.yml` | Cache L1 + invalidate |
| `config/litejob.yml` (generator) | Commented app template |
| `config/litecable` via `cable.yml` | Commented transport |
| `config/litecache.yml` (generator) | Commented L1 / invalidate |

Copy options into `config/litejob.yml`, `cable.yml`, or `cache_store` / YAML as needed.

### LiteBoard lifecycle

```yaml
# litejob options
lifecycle_stream: true
```

```bash
LITEBOARD_QUEUE_PATH=storage/production/queue.sqlite3 bin/liteboard
# UI: /topics/Litejob  ·  JSON: /topics/Litejob/lifecycle.json
```

---

## Status probe (is Honker active?)

```bash
# Live probe: gem load + LiteJob wakeup/backend + LiteCache invalidate + LiteCable transport
bundle exec rake litestack:honker:status

# Use your queue file (default: ephemeral tmp path)
LITESTACK_HONKER_PATH=storage/production/queue.sqlite3 bundle exec rake litestack:honker:status

# Fail-closed (exit 1 if gem missing, path not watchable, or any adapter inactive)
LITESTACK_HONKER_STRICT=1 bundle exec rake litestack:honker:status
```

From Ruby (boot check):

```ruby
report = Litestack::HonkerStatus.check(path: "storage/production/queue.sqlite3", strict: true)
abort Litestack::HonkerStatus.format(report) unless report[:ok]
```

Expect `litejob.wakeup: active`, `litejob.backend: active`, `litecache.invalidate: active`,
`litecable.transport: active` when the gem is installed and the path is a real file.

---

## CI / soak / benches

```bash
# Honker-focused tests
bundle exec rake test:honker

# Finite multi-process soak (LiteJob claim + LiteCache L1 drop)
bundle exec rake soak:honker
# or: bundle exec ruby scripts/soak_honker.rb --duration 15 --jobs 30

# LiteCache IPS gate (machine-local baseline + 95% floor)
bundle exec rake bench:litecache_l1
# full: baseline + l1_local + invalidate
bundle exec rake bench:litecache_l1_full
```

GitHub Actions job **Honker soak + LiteCache bench** runs on every push/PR to
`master` when Packages auth resolves.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `Authentication is required for rubygems.pkg.github.com` | `BUNDLE_RUBYGEMS__PKG__GITHUB__COM` or `bundle config` |
| Feature silently falls back to polling | `rake litestack:honker:status`; Honker load error, `:memory:` path, or extension missing |
| LiteBoard “lifecycle inactive” | `lifecycle_stream: true`, file path, `LITEBOARD_QUEUE_PATH` |
| Multi-worker stale cache with L1 | `invalidate: :honker` (or `:ttl`) and shared cache file path |
