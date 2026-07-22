# Honker-on Rails example

Minimal **Rails 8.1 + Litestack + Honker** app with:

| Area | Setting |
|------|---------|
| LiteJob wakeup | `wakeup: honker` |
| LiteJob backend | `backend: honker` (claim/ack + heartbeat) |
| Lifecycle stream | `lifecycle_stream: true` → LiteBoard feed |
| LiteCache | `l1: true`, `invalidate: honker` |
| LiteCable | `transport: honker` |

Configs live in this directory; the scaffold script copies them into a new app.

See also: [docs/HONKER.md](../../docs/HONKER.md).

---

## One command

From the **litestack repo root**:

```bash
# PAT needs read:packages (GitHub Packages hosts honker 0.4.0)
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="YOUR_GH_USERNAME:YOUR_PAT"

# Creates tmp/honker_rails by default, installs gems, overlays Honker configs, runs smoke
bundle exec rake examples:honker_rails

# Custom destination
DEST=/tmp/my_honker_app bundle exec rake examples:honker_rails
```

Or call the script directly:

```bash
bundle exec ruby scripts/create_honker_rails_app.rb tmp/honker_rails
```

Flags:

| Flag | Meaning |
|------|---------|
| `--skip-smoke` | Scaffold only; do not run the in-app smoke |
| `--force` | Replace an existing destination directory |
| `--rails-version 8.1.3` | Pin the Rails gem used by `rails new` |

---

## What the scaffold does

1. `rails new --minimal` (SQLite)
2. Adds `gem "litestack", path: <repo>` and `gem "honker", "0.4.0"` (Packages)
3. `bin/rails generate litestack:install`
4. Overlays Honker-on YAML from this folder
5. Enables `cache_store` / `queue_adapter` in **development** as well as production
6. Adds `DemoHonkerJob` and `script/smoke_honker.rb`
7. `db:prepare` + smoke runner

---

## After scaffold

```bash
cd tmp/honker_rails   # or your DEST

# Confirm adapters are active
LITESTACK_HONKER_PATH=storage/development/queue.sqlite3 \
  bundle exec ruby -e 'require "./config/environment"; puts Litestack::HonkerStatus.format(Litestack::HonkerStatus.check(path: "storage/development/queue.sqlite3"))'

# Re-run smoke
bin/rails runner script/smoke_honker.rb

# LiteBoard lifecycle UI (needs lifecycle_stream: true)
LITEBOARD_QUEUE_PATH=storage/development/queue.sqlite3 bundle exec liteboard
# → http://127.0.0.1:9292/topics/Litejob
```

Enqueue a job from console:

```bash
bin/rails runner 'DemoHonkerJob.perform_later("from-console")'
```

---

## Layout of this folder

```
examples/honker_rails/
  README.md
  config/litejob.yml                         # backend+wakeup+lifecycle
  config/litecache.yml                       # L1 + invalidate:honker
  config/cable.yml                           # transport:honker
  config/initializers/honker_ar_setup.rb     # load extension before Honker railtie bootstrap
  app/jobs/demo_honker_job.rb
  script/smoke_honker.rb
```

These files are **overlays** applied by `scripts/create_honker_rails_app.rb`; they are not a full Rails tree by themselves.

### Note on Honker’s Rails Railtie

Honker 0.4.0’s Railtie calls `Honker.bootstrap(AR)` without `load_extension`, which
fails with `no such function: honker_bootstrap`. The demo initializer
`honker_ar_setup.rb` loads the extension first. Litestack itself only soft-requires
Honker for queue/cache/cable files (not the primary AR DB).
