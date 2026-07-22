## [Unreleased]

- **Recurring tasks** (issue #101): Solid Queue–inspired schedules via
  `config/recurring.yml` or `recurring:` options. Cron / `every N` / simple
  English; enqueue into Litejob with slot dedupe + optional Honker leadership.
  Docs: `docs/RECURRING.md`, sample `samples/recurring.yml`, generator template.
- **Docs (1.1.0 install)**: README + `docs/RELEASE_GITHUB_PACKAGES.md` cover
  Packages-only install, visibility/`read:packages` permissions, and CI secret
  `BUNDLE_RUBYGEMS__PKG__GITHUB__COM` (no PAT rotation required in-repo).
- **CI**: `HonkerStatus` resets Litejobqueue singleton before live probe;
  Rails 8.1 integration asserts dynamic `Litestack::VERSION`.
- **Honker full-stack bench**: `bench/bench_honker_stack.rb` /
  `rake bench:honker_stack` multi-process job (poll vs honker), LiteCache L1 +
  invalidate, LiteCable latency; guide `docs/HONKER_FULL_STACK_BENCH.md`.

## [1.1.0] - 2026-07-22

Published to **GitHub Packages** (`rubygems.pkg.github.com/sunfang3`), not RubyGems.org.
See [docs/RELEASE_GITHUB_PACKAGES.md](docs/RELEASE_GITHUB_PACKAGES.md).

### Added — Honker integration (optional)

LiteJob and LiteCable can use the optional [`honker`](https://github.com/russellromney/honker) gem as a wake/coordination layer. Honker is **not** a hard dependency; without it, polling backends remain the default.

- **LiteJob wakeup** (`wakeup: :polling | :honker`): per-process shared wake signal with deadline-aware wait for delayed jobs. Honker watcher replaces multi-worker empty-queue SQL polling.
- **Queue notifications** (`queue_notify: true`, `wakeup_filter_notifications: true`): transactional `notify()` on push/repush so workers ignore pop/GC commits.
- **LiteJob backend** (`backend: :litequeue | :honker`): optional claim/ack/visibility-timeout backend for at-least-once execution after process crash.
- **LiteCable transport** (`transport: :polling | :honker`): cross-process broadcast via Honker notifications instead of 50ms message-table polling.
- Sample configs: `samples/litejob.honker.yml`, `samples/litecable.honker.yml`.
- Design notes: `docs/Integration_with_Honker.md`.
- **Transactional outbox** (`database: primary`, `outbox: true`): co-locate the
  LiteJob queue on the Rails primary SQLite file and enqueue on the open
  ActiveRecord connection so business rows and jobs share one COMMIT.
  Automatically sets `enqueue_after_transaction_commit: false`.
- **Leadership locks** (`leadership: true`): Honker named locks so only one
  process runs LiteJob GC / LiteCable pruner under multi-worker deploy.
- **JobHandle + results** (`job_results: true`): `perform_async` returns a
  `JobHandle` (`id, queue = handle` still works); `handle.wait(timeout:)` blocks
  until the worker stores the perform return value or a terminal failure.
- **Lifecycle stream** (`lifecycle_stream: true`): optional Honker stream of
  `job.enqueued` / `started` / `succeeded` / `retried` / `dead` events.
- **LiteCache L1 design review + regression bench**:
  `docs/plans/litecache-l1-honker-design-review.md`,
  `bench/bench_litecache_l1.rb` (`baseline` / `l1_local` / `compare` / `invalidate`).
- **LiteCache process-local L1** (opt-in, default off): `l1: true` with LRU
  (`l1_max_entries`), size skip (`l1_max_value_bytes`), optional soft TTL
  (`l1_ttl`).
- **LiteCache multi-process coherence** (opt-in):
  - `invalidate: :ttl` — soft L1 TTL bound (eventual consistency)
  - `invalidate: :honker` — same-file transactional `notify` + listener drops
    peer L1 (`notify_ops`, `notify_channel`); falls back to `:ttl` if Honker
    is unavailable. Soft TTL remains a lost-notify backstop.
- **LiteCache Rails Step 5**: ActiveSupport store forwards L1/invalidate options;
  install generator adds `config/litecache.yml` and production `cache_store`
  path under `storage/`; docs + `samples/litecache.honker.yml`. Defaults remain
  L1 off.
- **LiteBoard job lifecycle feed**: Litejob topic page shows Honker lifecycle
  stream events (`lifecycle_stream: true`); JSON at
  `/topics/Litejob/lifecycle.json` with 5s JS poll. Path via
  `LITEBOARD_QUEUE_PATH` / `LITEJOB_PATH` / default queue.sqlite3.
- **Honker docs + generator templates**: `docs/HONKER.md` (install from GitHub
  Packages `sunfang3`, capability matrix); generator adds `config/litejob.yml`
  and comments on cable/cache; README / `RAILS_FULL_STACK.md` app Gemfile recipe.
- **Outbox `table_prefix`**: co-located primary DB uses `litestack_queue` by
  default (`table_prefix: "litestack_"`) so an app table named `queue` is safe;
  schema on primary avoids `PRAGMA user_version`. Standalone queues stay
  unprefixed (`queue`).
- **Honker long-job heartbeat**: while `perform` runs under `backend: :honker`,
  periodically `heartbeat` the claim (`heartbeat_interval`, `heartbeat_extend`)
  so jobs longer than `visibility_timeout` are not reclaimed mid-run.
- **CI + soak**: workflow authenticates to GitHub Packages for `honker`;
  `rake test:honker`, `rake soak:honker` (`scripts/soak_honker.rb`), and
  `rake bench:litecache_l1` (baseline + compare) on exact-target / soak jobs.
- **Honker status probe**: `rake litestack:honker:status` /
  `Litestack::HonkerStatus` reports gem load and live activation of LiteJob
  wakeup/backend, LiteCache invalidate, and LiteCable transport
  (`LITESTACK_HONKER_STRICT=1` for fail-closed exit).
- **Honker Rails example**: `examples/honker_rails/` overlays +
  `rake examples:honker_rails` / `scripts/create_honker_rails_app.rb` scaffold a
  minimal Rails 8.1 app with backend+wakeup+L1+cable+lifecycle and a smoke runner.


## [1.0.0] - 2026-07-17

- **Breaking:** Require Ruby `>= 4.0`; drop Ruby 3.x support.
- **Breaking:** Rails integrations require Rails `>= 8.1, < 9` (Rails 7.x / 8.0 unsupported). Raises `Litestack::UnsupportedFrameworkVersionError` at adapter/Railtie entry points. Rails remains optional at gem runtime.
- Modernize Active Record Litedb adapter for Rails 8.1 registered-adapter path; remove connection-handler test monkey patches and copied dbconsole patch.
- Align Litecache Active Support store (no global `format_version` mutation), Litejob Active Job adapter (`AbstractAdapter`, `stopping?`, queue-safe enqueue), and Litecable Action Cable subscription adapter.
- Idempotent connection/worker/scheduler/`at_exit` lifecycle; named `ClosedError` / `ShutdownTimeoutError`.
- Central `SchemaMigrator` with advisory + write locks, WAL-consistent verified backups before destructive upgrades, transactional steps, and failure recovery.
- Durable upgrade fixtures and tests for published 0.4.3 and pre-modernization 0.4.5 (`e598e1b`).
- Liteboard: Rack 3 responses, security headers, CSP, local CSS/JS (no remote CDN/`eval`), empty/error routes, accessible landmarks.
- Install generator: safer idempotent edits; never auto-deletes Solid Cache/Queue; prints optional cleanup guidance.
- CI matrix: Ruby 4.0.0+Rails 8.1.0, Ruby 4.0.5+Rails 8.1.3, latest Ruby 4.x+Rails 8.x; package verification; non-blocking head.
- Coverage harness starts before project load; sqlite3 runtime constrained to 2.x; version 1.0.0 metadata consistency.
- Migration guide: `docs/MIGRATING_TO_RUBY4_RAILS81.md`

### Carried from pre-1.0 master

- Fix a table not defined bug for Litesearch
- Add conditional mapping of external fields to Litesearch (backed index)
- As a consequence of the above, support AR polymorphic associations
- As a consequence of the above, support indexing and searching for ActionText attributes
- Remove 'hanami-router' as a dependency, rely on vanilla Rack for Liteboard 


## [0.4.3] - 2024-02-15

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.4.2...v0.4.3)
- Add "sequel" as a development dependency
- Diff links in CHANGELOG (thanks Weston Ganger)
- Fix daemonize type in liteboard (thanks Julian Rubisch)
- Better Litecache schema (streamlined numeric value support)
- Support for set_multi and get_multi in Litecache (read_multi and write_multi support for Rails Cache store)
- More tests written for Litecache and Rails Litecache store
- Experimenting with removing the Rails LocalCache as it doesn't show enough improvement in performance to compensate for the memory overhead
- Switch Litecache to a FIFO eviction model vs LRU (thanks Julian Rubisch and Stephen Margheim)

## [0.4.2] - 2023-11-11

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.4.1...v0.4.2)
- Add similarity search support for Litesearch (works best for non-trigram indexes)
- Enable similarity search for ActiveRecord and Sequel models
- Fix Litesearch tests
- Suppress chatty Litejob exit detector when there are no jobs in flight
- Tidy up the test folder
- [#41](https://github.com/oldmoe/litestack/pull/41) - Fix bug in Litecable where the `connected` event was not getting propagated
- Add Litemetric and Liteboard info to README.doc
- Fix the testing rake task

## [0.4.1] - 2023-10-11

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.4.0...v0.4.1)
- Add missing Litesearch::Model dependency

## [0.4.0] - 2023-10-11

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.3.0...v0.4.0)
- Introduced Litesearch, dynamic & fast full text search capability for Litedb
- ActiveRecord and Sequel integration for Litesearch
- Slight improvement to the Sequel Litedb adapter for better Litesearch integration

## [0.3.0] - 2023-08-13

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.2.6...v0.3.0)
- Reworked the Litecable thread safety model
- Fixed multiple litejob bugs (thanks Stephen Margheim)
- Fixed Railtie dependency (thanks Marco Roth)
- Litesupport fixes (thanks Stephen Margheim)
- Much improved metrics reporting for Litedb, Litecache, Litejob & Litecable
- Removed (for now, will come again later) litemetric reporting support for ad-hoc modules

## [0.2.6] - 2023-07-16

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.2.3...v0.2.6)
- Much improved database location setting (thanks Brad Gessler)
- A Rails generator for better Rails Litestack defaults (thanks Brad Gessler)
- Revamped Litemetric, now much faster and more accurate (still experimental)
- Introduced Liteboard, a dashboard for viewing Litemetric data

## [0.2.3] - 2023-05-20

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.2.2...v0.2.3)
- Cut back on options defined in the Litejob Rails adapter

## [0.2.2] - 2023-05-18

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.2.1...v0.2.2)
- Fix default queue location in Litejob


## [0.2.1] - 2023-05-08

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.2.0...v0.2.1)
- Fix a race condition in Litecable

## [0.2.0] - 2023-05-08

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.1.8...v0.2.0)
- Litecable, a SQLite driver for ActionCable
- Litemetric for metrics collection support (experimental, disabled by default)
- New schema for Litejob, old jobs are auto-migrated
- Code refactoring, extraction of SQL statements to external files
- Graceful shutdown support working properly
- Fork resilience

## [0.1.8] - 2023-03-08

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.1.7...v0.1.8)
- More code cleanups, more test coverage
- Retry support for jobs in Litejob
- Job storage and garbage collection for failed jobs
- Initial graceful shutdown support for Litejob (incomplete)
- More configuration options for Litejob

## [0.1.7] - 2023-03-05

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.1.6...v0.1.7)
- Code cleanup, removal of references to older name
- Fix for the litedb rake tasks (thanks: netmute)
- More fixes for the new concurrency model
- Introduced a logger for the Litejobqueue (doesn't work with Polyphony, fix should come soon)

## [0.1.6] - 2023-03-03

- [View Diff](https://github.com/oldmoe/litestack/compare/v0.1.0...v0.1.6)
- Revamped the locking model, more robust, minimal performance hit
- Introduced a new resource pooling class
- Litecache and Litejob now use the resource pool
- Much less memory usage for Litecache and Litejob

## [0.1.0] - 2023-02-26

- Initial release
