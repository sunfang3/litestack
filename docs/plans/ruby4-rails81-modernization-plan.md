# Ruby 4 and Rails 8.1 Modernization Implementation Plan

**Version:** 1.0
**Status:** Draft
**Date:** 2026-07-17
**Requirements:** `docs/plans/ruby4-rails81-modernization-requirements.md`

## Target Architecture

Litestack remains a layered gem rather than becoming a Rails-only package. `lib/litestack.rb` is the optional-integration entry point; the standalone components continue to sit above `Litesupport::Liteconnection`, the scheduler/pool layer, and sqlite3. Rails-facing files remain thin adapters registered through public Rails 8.1 extension points: Active Record adapter registration, Active Job's adapter interface, Active Support's cache-store interface, Action Cable's subscription interface, and a Railtie/generator for application configuration. Sequel remains an optional peer integration.

Durable schema evolution is centralized behind one small migrator used by the shared connection path and Litesearch's destructive schema/rebuild path. It requires old processes to be quiesced, acquires cooperative process and SQLite write locks, reads `PRAGMA user_version`, validates the source, runs ordered steps transactionally, and uses separate read-source and destination connections to publish a fully verified sidecar backup before any destructive change. Component SQL YAML remains the source of versioned schema steps. Ephemeral Litecache/Litecable files are rebuildable; Litedb, Litejob, Litesearch, LiteKD, and Litemetric receive historical fixture tests.

Verification has three layers: component Minitest contracts, a built-gem Rails 8.1 temporary-application smoke test, and package/release checks. The blocking environments are the Ruby 4.0.0 + Rails 8.1.0 lower bound, the exact Ruby 4.0.5 + Rails 8.1.3 target, the latest released Ruby 4.x + Rails 8.x pair, and both minimum/latest cross-corners within the declared bounds, all with sqlite3 2.x. Rails main/Ruby head are warnings only. CI builds the gem before the Rails application test so path-source behavior cannot hide packaging or load-path defects.

## Implementation Phases

1. **Foundation:** Units 1–3 establish resolvable dependencies, a trustworthy quality gate, and safe runtime lifecycle behavior.
2. **Framework contracts:** Units 4–8 modernize each Rails integration and generator independently.
3. **Data and application proof:** Units 9–12 implement recoverable migration behavior, historical fixtures, and a real Rails application smoke test.
4. **Experience and delivery:** Units 13–20 make CI/package verification, Liteboard, utilities, benchmarks, documentation, and the breaking release internally consistent.

### Unit 1: Ruby 4 and Rails 8.1 Dependency Baseline

**Goal:** Make the repository bundle resolve deterministically on Ruby 4.0.5 and Rails 8.1.3 while declaring the new support floor.

**Requirements trace:** R1, R2, R3, R14, R15

**Dependencies:** None.

**Files:**
- `litestack.gemspec` — require Ruby 4, update sqlite3/stdlib/development constraints, and remove Rails 7-only development pins.
- `Gemfile` — make Rails 8.1.3 the exact default development target alongside the gemspec.
- `.ruby-version` — pin the blocking local/CI runtime to 4.0.5.
- `gemfiles/rails70.gemfile` — remove the unsupported Rails 7.0 definition.
- `gemfiles/rails71.gemfile` — remove the unsupported Rails 7.1 definition.
- `gemfiles/rails71.gemfile.lock` — remove the stale arm64-Darwin/Bundler 2 lock.
- `lib/litestack/compatibility.rb` — enforce the optional Rails integration support band without making Rails a runtime dependency.
- `test/test_compatibility.rb` — cover supported, missing, too-old, and too-new framework versions.

**Approach:** Keep Rails optional at gem runtime: do not add Rails as a runtime dependency. Remove Active Record/Active Job/Railties version pins from development metadata and put the exact supported development stack in `Gemfile`. Set `required_ruby_version` to `>= 4.0`; constrain sqlite3 to the Rails-compatible 2.x band; add explicit runtime dependencies on directly required Ruby 4 bundled gems `logger`, `base64`, and `bigdecimal`; and align Minitest/tool versions with Ruby 4. Add a small compatibility check, called before version-specific internals whenever a Railtie or Rails adapter is loaded, that accepts Rails `>= 8.1, < 9` and raises `Litestack::UnsupportedFrameworkVersionError` otherwise; standalone `require "litestack"` remains Rails-free. Do not commit a platform-specific lock for the library unless it contains all supported platforms and is demonstrably useful.

**Patterns:** Preserve the existing gemspec/Gemfile separation and optional framework loading in `lib/litestack.rb`; use the current `gemfiles/` convention only for non-blocking future-framework checks added later.

**Test scenarios:**
- [ ] Happy path: `bundle install` resolves Rails 8.1.3 and sqlite3 2.x on Ruby 4.0.5/Bundler 4.
- [ ] Nil/empty input: building the gem without Rails loaded still resolves all standalone runtime dependencies.
- [ ] Error path: Ruby 3.x installation is rejected by gem metadata with a clear required-version error.
- [ ] Edge case: package dependency inspection confirms Rails was not accidentally made a runtime dependency.
- [ ] Edge case: Rails 8.0 and Rails 9 adapter/Railtie entry points fail with the named compatibility error while Rails 8.1 succeeds.
- [ ] Edge case: an isolated installed-gem process loads `logger`, `base64`, and `bigdecimal` without relying on repository development dependencies.

**Verification:** `ruby -v`, `bundle platform`, `bundle exec ruby -e 'require "rails"; abort unless Rails.version == "8.1.3"'`, and `gem specification ./litestack-*.gem required_ruby_version dependencies` show the chosen contract.

**Planning-time unknowns:** Deferred to Planning — select the latest sqlite3 2.x patch available when implementation starts, then exact-pin it only in the development target while keeping the runtime requirement within 2.x.

### Unit 2: Trustworthy Test and Style Harness

**Goal:** Ensure coverage and quality checks start before Litestack loads and produce one authoritative pass/fail result.

**Requirements trace:** R1, R4, R13, R14

**Dependencies:** Unit 1.

**Files:**
- `Rakefile` — expose deterministic test, style, coverage, and combined verification tasks.
- `test/helper.rb` — start SimpleCov before project requires and centralize shared cleanup.
- `test/Rakefile` — delegate to the root harness or remove the divergent secondary task definition.
- `.standard.yml` — target Ruby 4.0 and define intentional exclusions narrowly.
- `.simplecov` — centralize line/branch measurement, result merging, and minimum thresholds.
- `test/test_litescheduler.rb` — make the scheduler double implement Ruby 4's required callbacks.

**Approach:** Preload `test/helper.rb` through the Rake test command before any test file, rather than editing every test solely for require order. Reset global queues, scheduler state, threads, connections, and constants in shared hooks. Make the scheduler test double explicitly implement the Ruby 4 hooks exercised by Litestack and core: `block`, `unblock`, `kernel_sleep`, `io_wait`, `fiber_interrupt`, `fiber`, `yield`, and cleanup/`close`; capture stderr so a missing-hook warning fails. Measure a clean full-suite baseline first and set non-regression thresholds to that measured result. Enforce 100% line and branch coverage on new compatibility files and materially changed branches through per-file checks; any genuinely unreachable exclusion is named, justified, and reviewed instead of silently omitted. Configure Standard for Ruby 4 and fix only blocking/currently touched code in later units; isolate legacy style debt explicitly instead of claiming it passes.

**Patterns:** Continue using Minitest and `Rake::TestTask`; retain the existing shared helper and Standard Rake integration rather than introducing a second test framework.

**Test scenarios:**
- [ ] Happy path: the full suite produces one coverage report after all 158+ tests finish.
- [ ] Nil/empty input: running a single test file still initializes coverage and cleanup safely.
- [ ] Error path: an intentionally lowered coverage result makes the coverage task exit non-zero.
- [ ] Edge case: randomized test seeds run repeatedly without Litejob/global-state count leakage.
- [ ] Edge case: an uncovered branch in a newly added compatibility file fails its per-file 100% gate even when aggregate coverage remains above baseline.
- [ ] Edge case: scheduler-backed spawn, mutex contention, IO close/interrupt, yield, and scheduler close complete with empty stderr on Ruby 4.0.5.

**Verification:** `bundle exec rake test`, `bundle exec rake standard`, and `bundle exec rake verify` all exit zero; coverage timestamps and file counts prove project code was measured after the suite, and repeated seeds remain green.

**Planning-time unknowns:** Deferred to Planning — set the initial line and branch thresholds from the first valid, clean full-suite measurement; record the numbers in `.simplecov` and the plan implementation notes.

### Unit 3: Idempotent Runtime Lifecycle

**Goal:** Make pools, connections, statements, workers, scheduler state, forks, and exit hooks safe to start and stop repeatedly on Ruby 4/sqlite3 2.x.

**Requirements trace:** R1, R4, R10, R18

**Dependencies:** Units 1 and 2.

**Files:**
- `lib/litestack/liteconnection.rb` — make close/at-exit behavior stateful, idempotent, and statement-close aware.
- `lib/litestack/litescheduler.rb` — satisfy Ruby 4 scheduler semantics and reset correctly after fork.
- `lib/litestack/litecache.rb` — stop and join the pruning worker before closing its connection.
- `lib/litestack/litecable.rb` — stop and join listener/pruner/broadcaster workers before closing.
- `lib/litestack/litejobqueue.rb` — coordinate dispatcher/worker shutdown and restart after fork.
- `lib/litestack/litemetric.rb` — close collector resources and workers deterministically.
- `lib/litestack/litesupport.rb` — drain and close every pooled resource and reject acquires after closing begins.
- `test/test_lifecycle.rb` — add cross-component start/close/double-close/fork contract coverage.

**Approach:** Detect the scheduler from the current thread/current state rather than a process-global cache; always use real mutex synchronization and let Ruby's scheduler hooks handle Fiber contention. Introduce explicit running/closing/shutdown_failed/closed states plus a scheduler-aware stop/wake primitive and uniform handle `wait`/`alive?` behavior for Thread and Fiber contexts. Track every long-lived and per-job/snapshot handle. Shutdown order is: atomically enter closing, reject or apply the component's documented defer policy to new work, signal and wake sleepers, drain/wait for the configurable five-second default, close every statement and every pooled database only after no task can touch them, then mark closed. On timeout, do not close SQLite under a live task; enter retryable `shutdown_failed`, raise `Litestack::ShutdownTimeoutError`, emit structured state/handle diagnostics, and let a later close retry deterministically. Pool close blocks new acquires with `Litestack::ClosedError`, waits for in-flight leases, and drains all configured resources rather than requeueing a closed handle. Fork listener registrations use removable tokens or state guards: live objects initialize once in the child, closed objects remain closed. Ruby 4 clears the host Fiber scheduler after fork, and Litestack neither closes nor unsets an application-owned scheduler. Neutralize exit callbacks after explicit close and do not rescue `Exception` to hide lifecycle defects. Fold standalone Litemetric capture, aggregation, snapshot, empty, and shutdown behavior into the lifecycle contract test.

**Patterns:** Extend the existing `Liteconnection`, `Litescheduler.spawn`, `ForkListener`, and component `setup`/`close` hooks rather than adding a parallel process manager.

**Test scenarios:**
- [ ] Happy path: every stateful component starts, performs one operation, closes, and releases all worker handles.
- [ ] Nil/empty input: closing an initialized component with no queued work/messages/metrics succeeds.
- [ ] Error path: an unwakeable/live worker reaches named `shutdown_failed` without its SQLite handle being closed; after release, a repeated close drains and reaches closed.
- [ ] Error path: a worker exception is reported with its component/handle identity; once the task is dead, remaining resources still drain and close.
- [ ] Edge case: calling `close`/`shutdown` twice and then running `at_exit` produces no closed-statement exception.
- [ ] Edge case: scheduler and non-scheduler threads select independent backends; scheduler set/unset transitions do not use stale state.
- [ ] Edge case: a fiber-backed parent forks to a scheduler-free child with fresh handles, a child may install a fresh scheduler, and a closed parent object is never reopened.
- [ ] Edge case: a pool with multiple resources closes all statements/handles across an in-flight acquire race and rejects post-close acquisition.
- [ ] Edge case: subprocess implicit exit and explicit close-then-exit complete within the bound with empty lifecycle stderr for every stateful component.

**Verification:** `bundle exec ruby -Itest test/test_lifecycle.rb` exits zero under sqlite3 2.x, reports no surviving Litestack threads/fibers or pooled handles, passes the thread/fork/subprocess matrices, and reproduces then eliminates the previously observed `cannot use a closed statement` failure.

**Planning-time unknowns:** None; the default shutdown timeout is five seconds and remains configurable for applications with measured longer drains.

### Unit 4: Rails 8.1 Active Record and Sequel Contracts

**Goal:** Establish and operate Litedb/search connections through the supported Rails 8.1 and Sequel adapter paths without test monkey patches.

**Requirements trace:** R2, R4, R5, R9, R18

**Dependencies:** Units 1–3.

**Files:**
- `lib/active_record/connection_adapters/litedb_adapter.rb` — adopt the Rails 8.1 adapter construction/client contract and preserve Litedb behavior.
- `lib/litestack.rb` — stop conditionally loading the copied dbconsole patch and load adapter registration safely.
- `lib/sequel/adapters/litedb.rb` — preserve the optional Sequel adapter/search contract on Ruby 4 and sqlite3 2.x.
- `test/test_ar_search.rb` — exercise the registered adapter through normal configuration.
- `test/patch_ar_adapter_path.rb` — remove the connection-handler monkey patch.
- `test/test_litedb_rails.rb` — cover connection, schema, CRUD, reconnect, errors, and adapter dbconsole dispatch.
- `test/test_litedb.rb` — verify standalone Litedb query, statement, transaction, metrics, empty, and error behavior.
- `test/test_sequel_search.rb` — exercise Litedb and Litesearch through Sequel without Rails constants loaded.

**Approach:** Retain `ActiveRecord::ConnectionAdapters.register`, delete the obsolete `ConnectionHandling#litedb_connection` and custom `connect`, and override only the Rails 8.1 class-level `new_client(config)` seam to return `::Litedb`; the inherited initializer/connect/reconnect flow continues to own path normalization, connection parameters, configuration, and pool context. Explicitly override `.native_database_types` to return Litedb's frozen mapping because the inherited method is lexically bound to SQLite3Adapter's constant; assert `:unixtime`, primary key, string/date-time types, and schema dump. Keep dbconsole in the adapter's public class method and dispatch through injectable `ActiveRecord.database_cli[:sqlite]`; do not reopen Rails command classes. Raise Rails exceptions with pool/context information where Rails expects it. Load Sequel only when present and exercise its public adapter/database hooks independently so Rails compatibility work cannot hide a peer-integration regression.

**Patterns:** Follow Rails 8.1's installed `SQLite3Adapter` and Sequel's public adapter interfaces while keeping Litestack-specific behavior inside the existing Litedb adapter boundaries.

**Test scenarios:**
- [ ] Happy path: `ActiveRecord::Base.establish_connection(adapter: "litedb")` migrates, inserts, queries, reconnects, and dumps schema.
- [ ] Nil/empty input: missing/blank database configuration raises the expected Rails error with connection context.
- [ ] Error path: a nonexistent/unwritable database path raises `ActiveRecord::NoDatabaseError` rather than a raw system exception.
- [ ] Edge case: in-memory and URI-style SQLite database paths are not expanded as filesystem paths.
- [ ] Edge case: dbconsole delegates to `LitedbAdapter.dbconsole` without changing other adapters' behavior.
- [ ] Edge case: Sequel Litedb/search loads and queries when Rails and Active Record are absent.
- [ ] Edge case: native types and schema dump use Litedb's own frozen mapping rather than the inherited SQLite mapping.

**Verification:** The new AR tests pass without requiring `test/patch_ar_adapter_path.rb`; a Rails 8.1 process reports `adapter_name == "litedb"` and executes migration/CRUD/dbconsole smoke paths, and the Sequel contract passes in a separate Rails-free process.

**Planning-time unknowns:** None; Rails 8.1.3's installed connection flow calls `self.class.new_client(@connection_parameters)` from the inherited `connect`, so the class-level client override is the single required construction seam.

### Unit 5: Rails 8.1 Active Support Cache Contract

**Goal:** Make Litecache a conforming Rails 8.1 cache store without mutating application-global serialization settings.

**Requirements trace:** R2, R4, R6, R10, R18

**Dependencies:** Units 1–3.

**Files:**
- `lib/active_support/cache/litecache.rb` — remove global format mutation and align cache-store private/public method contracts.
- `lib/litestack/litecache.rb` — expose atomic primitives needed by the Rails store and use the shared lifecycle contract.
- `test/test_cache_rails.rb` — expand Rails cache behavior and serialization coverage.
- `test/test_cache.rb` — retain standalone behavior and cross-check atomic operations.
- `test/test_cache_store_contract.rb` — add focused Rails 8.1 store contract/edge-case tests.

**Approach:** Use Rails 8.1's `serialize_entry`/`deserialize_entry` and remove `ActiveSupport::Cache.format_version = 7.0`. Respect the asymmetric multi contract: `read_multi_entries` receives original names and must normalize each lookup, batch-read, deserialize, enforce expiration/version, and return a hash keyed by the original caller names; `write_multi_entries` receives normalized keys mapped to `Entry` objects and transforms them non-destructively. Align `cleanup(options = nil)` with the Store public signature instead of exposing the engine's `(limit, time)` parameters. Ensure counters and conditional writes are atomic with documented return values. Keep cache files rebuildable and avoid durable migration complexity.

**Patterns:** Mirror Rails 8.1's MemoryStore/RedisCacheStore method signatures while delegating storage to existing `Litecache` primitives.

**Test scenarios:**
- [ ] Happy path: single/multi fetch, expiration, counters, conditional writes, namespaces, and clear/cleanup match Rails expectations.
- [ ] Nil/empty input: empty multi-read/write and nil payloads return the Rails-defined shapes without SQL errors.
- [ ] Error path: corrupt serialized payload is treated as a miss and surfaced through Rails instrumentation rather than crashing the process.
- [ ] Edge case: constructing Litecache leaves the host application's cache format/coder unchanged.
- [ ] Edge case: caller hashes passed to `write_multi` remain unmodified.
- [ ] Edge case: namespaced, versioned, expired, duplicate/compound, and corrupt multi-read keys return Rails-defined original-key shapes and miss semantics.

**Verification:** `bundle exec ruby -Itest test/test_cache_store_contract.rb` and existing cache suites pass; before/after assertions prove no global cache format mutation.

**Planning-time unknowns:** None; cache persistence is explicitly ephemeral and Rails 8.1's installed Store contract is authoritative.

### Unit 6: Rails 8.1 Active Job Contract

**Goal:** Make Litejob a complete Rails 8.1 queue adapter with deterministic transaction and stopping behavior.

**Requirements trace:** R2, R4, R7, R10, R18

**Dependencies:** Units 1–3.

**Files:**
- `lib/active_job/queue_adapters/litejob_adapter.rb` — inherit/implement the Rails 8.1 adapter contract and stopping state.
- `lib/litestack/litejob.rb` — preserve queue selection and explicit adapter lifecycle semantics.
- `lib/litestack/litejobqueue.rb` — expose safe shutdown/stopping state and transaction-aware enqueue behavior.
- `test/test_litejob_rails.rb` — remove global leakage and expand Rails behavior.
- `test/test_litejob.rb` — preserve standalone scheduling/retry semantics.
- `test/test_jobqueue.rb` — verify queue persistence, retry, and shutdown primitives.
- `test/test_active_job_contract.rb` — cover Rails 8.1 adapter, transactions, continuations/stopping, and serialization.

**Approach:** Derive from `ActiveJob::QueueAdapters::AbstractAdapter`, implement `enqueue`/`enqueue_at`, and assign `job.provider_job_id = persisted_result[0].to_s`; Rails ignores the adapter method return value. Use the inherited stopping state. Do not retain or invent an adapter-level `enqueue_after_transaction_commit?` hook: Rails 8.1 applies the job class's `enqueue_after_transaction_commit` policy through `ActiveRecord.after_all_transactions_commit`, including `perform_all_later`. Ensure queue name is not stored in a racy global class attribute across simultaneous enqueues; pass it with each push. Once stopping begins, new enqueues and a continuation's checkpoint-triggered retry remain durably accepted for a later process but the draining dispatcher cannot claim them locally; emit a structured deferred-during-shutdown event. Keep Active Job serialization authoritative and exercise retry/scheduled timestamps under Ruby 4.

**Patterns:** Follow Rails 8.1 built-in adapters' interface while continuing to use `Litejobqueue` as the standalone engine.

**Test scenarios:**
- [ ] Happy path: immediate, asynchronous, scheduled, retrying, named-queue, and after-commit jobs execute once with correct arguments.
- [ ] Nil/empty input: empty arguments and the default queue serialize and perform correctly.
- [ ] Error path: job failure records the named exception, retry count, and final failure without losing the durable job.
- [ ] Edge case: job-class transaction policy `true` defers until commit/omits rollback, `false` enqueues immediately, and `perform_all_later` partitions both policies correctly.
- [ ] Edge case: at a continuation checkpoint, adapter stopping persists the serialized retry/progress for another process and neither it nor a concurrent new enqueue is claimed locally.
- [ ] Edge case: immediate and scheduled jobs set stable string provider IDs from the persisted queue row.

**Verification:** Existing and new Active Job suites pass under Rails 8.1.3; randomized concurrent named-queue tests show no queue-name cross-talk; shutdown leaves no jobs silently in flight.

**Planning-time unknowns:** None; new work during stopping is persisted for the next process and never silently discarded or started by the draining process.

### Unit 7: Rails 8.1 Action Cable Contract

**Goal:** Make Litecable a conforming subscription adapter whose message and shutdown behavior is safe under Rails 8.1.

**Requirements trace:** R2, R4, R8, R10, R18

**Dependencies:** Units 1–3.

**Files:**
- `lib/action_cable/subscription_adapter/litecable.rb` — require the public adapter modules explicitly and align initialization/shutdown behavior.
- `lib/litestack/litecable.rb` — use the idempotent lifecycle and preserve subscriber/message safety.
- `test/test_litecable.rb` — add standalone local/cross-instance messaging tests.
- `test/test_action_cable_contract.rb` — test the Rails 8.1 server/config/channel-prefix adapter contract.

**Approach:** Explicitly load Rails' `Base` and channel-prefix module, inherit `ActionCable::SubscriptionAdapter::Base`, prepend `ChannelPrefix`, and compose a `::Litecable` engine rather than inheriting the storage engine as the adapter. Accept the Rails server object contract and deliver subscription callbacks through `server.event_loop` so a subscriber exception cannot kill the SQLite listener. Keep Litestack's local and SQLite-backed delivery paths, synchronize subscriber mutation, use the Base logger contract, and make shutdown wait for broadcaster/listener/pruner completion before the shared connection closes.

**Patterns:** Follow Rails 8.1's PostgreSQL/Redis subscription adapter signatures and retain `Litecable` as the storage/delivery engine.

**Test scenarios:**
- [ ] Happy path: subscribe, prefixed broadcast, receive, unsubscribe, and shutdown work with a Rails server/config object.
- [ ] Nil/empty input: no prefix and no subscribers produce no error or phantom delivery.
- [ ] Error path: malformed stored JSON or a subscriber exception is reported without killing all adapter workers.
- [ ] Error path: callback delivery is isolated on the Rails event loop and a failed subscriber does not block a healthy subscriber.
- [ ] Edge case: two adapter instances exchange one SQLite-backed message without re-delivering the sender's message.
- [ ] Edge case: explicit shutdown followed by `at_exit`/second shutdown is silent and idempotent.

**Verification:** The contract test reproduces real Rails 8.1 channel prefixing and exits zero twice after shutdown; worker/thread accounting returns to baseline.

**Planning-time unknowns:** None; Rails 8.1's installed subscription adapters provide the target contract.

### Unit 8: Rails 8.1 Railtie and Install Generator

**Goal:** Configure a fresh or existing Rails 8.1 application safely and observably without fragile text substitutions or destructive overwrites.

**Requirements trace:** R2, R4, R9, R12, R16, R18

**Dependencies:** Units 1–7.

**Files:**
- `lib/litestack/railtie.rb` — use supported configuration/load hooks and gate Active Record settings safely.
- `lib/generators/litestack/install/install_generator.rb` — replace fragile spacing matches and force-overwrite behavior with structured, idempotent edits.
- `lib/generators/litestack/install/templates/database.yml` — provide Rails 8.1-compatible Litedb configuration examples.
- `lib/generators/litestack/install/templates/cable.yml` — provide Rails 8.1-compatible Litecable configuration.
- `lib/generators/litestack/install/USAGE` — document generated changes and Solid Cache/Queue coexistence/removal choices.
- `lib/railties/rails/commands/dbconsole.rb` — remove the copied `Rails::DBConsole#start` implementation now that the adapter owns dispatch.
- `test/test_install_generator.rb` — assert fresh/existing/idempotent generator behavior.
- `test/test_railtie.rb` — boot with/without Active Record and assert initializer behavior.

**Approach:** Remove the obsolete `sqlite3_production_warning` initializer, which Rails 8.1 no longer defines, and use `ActiveSupport.on_load` plus normal initializers only for settings Litestack still owns. Modify only owned keys/lines and preserve unrelated database entries, including Rails 8.1's `max_connections`, `timeout`, and Solid service databases. For a default Rails 8.1 application, set Litestack adapters explicitly but do not delete `solid_cache`, `solid_queue`, their migrations, or arbitrary Gemfile content automatically; print exact optional cleanup guidance instead. For each source edit, accept either the original source line or the already-generated target as an explicit precondition; if neither exists, raise a named `Thor::Error` instead of treating a no-op `gsub_file` as success. Make reruns no-ops and use Railtie load hooks rather than eager constant mutation.

**Patterns:** Retain Rails generator actions (`copy_file`, `inject_into_file`, `gsub_file`) only where exact postconditions are asserted; follow the current small Railtie initializer style.

**Test scenarios:**
- [ ] Happy path: a default Rails 8.1 app receives Litedb/Litecache/Litejob/Litecable configuration and boots.
- [ ] Nil/empty input: an app without Active Record skips database-specific changes while configuring available components.
- [ ] Error path: an unrecognized production configuration produces a clear generator failure/warning instead of silent success.
- [ ] Error path: a missing source and target line raises `Thor::Error` and leaves every configuration file unchanged.
- [ ] Edge case: an existing multi-database `database.yml` retains all unrelated databases and credentials.
- [ ] Edge case: running the generator twice yields no duplicate config or `.gitignore` entries.

**Verification:** Generator tests compare full postconditions, not console output only; Railtie tests boot isolated Rails application classes with expected settings and no deprecations.

**Planning-time unknowns:** None; Solid Cache/Queue are superseded by configuration but never removed automatically, resolving generator behavior conservatively.

### Unit 9: Recoverable Durable Schema Migrator

**Goal:** Centralize validated, transactional, backup-aware forward schema upgrades for durable components.

**Requirements trace:** R4, R10, R11, R18

**Dependencies:** Units 2 and 3.

**Files:**
- `lib/litestack/schema_migrator.rb` — implement preflight, version ordering, destructive-step backup, transaction, verification, and recovery.
- `lib/litestack/liteconnection.rb` — delegate SQL YAML schema application to the migrator.
- `lib/litestack/litesupport.rb` — define named migration/backup errors and shared filesystem helpers.
- `lib/litestack/litesearch/index.rb` — route `WRITABLE_SCHEMA`, index rebuild, drop, and destructive field changes through the same protection boundary.
- `test/test_schema_migrator.rb` — cover no-op, additive, destructive, invalid, and injected-failure paths.
- `test/test_litesearch_schema_migration.rb` — verify protected schema edits/rebuilds preserve searchable rows and recover on failure.

**Approach:** Preserve SQL YAML and `PRAGMA user_version` as the migration source of truth. Parse packaged SQL definitions with safe YAML loading, validate the complete shape and monotonically ordered integer versions, and reject transaction control, `VACUUM`, journal-mode changes, or other statements incompatible with the managed transaction using `Litestack::InvalidMigrationError`. Require the operator to quiesce old Litestack processes. Acquire a sibling advisory lock, run static path/permission/free-space checks plus source `quick_check`, then obtain a bounded SQLite `BEGIN IMMEDIATE` on migration connection A; raise `Litestack::MigrationBusyError` before mutation if either lock fails and hold A's write transaction through commit/rollback.

If any pending step is destructive, create the snapshot before executing any step with three distinct roles: A remains the locked migration connection, independent read-only connection B is the online-backup source for the last committed state, and connection C writes a sibling partial file pre-created via `File::CREAT | File::EXCL` with mode `0600` and reopened without CREATE. Never use A as the backup source. Treat `SQLite3::Backup#step` integer results explicitly: retry only `BUSY`/`LOCKED` within a bound, accept only `DONE`, and raise `Litestack::BackupError` immediately on `READONLY`, `NOMEM`, or `IOERR_*`. Every successful `Backup.new` receives exactly one `finish`, followed by C then B close in `ensure`; no schema SQL begins after any backup error. Reopen the closed snapshot read-only, require full `PRAGMA integrity_check` to return the single row `ok` and `PRAGMA foreign_key_check` to return no rows, run component semantic checks for Litesearch, and raise `Litestack::BackupIntegrityError` on any mismatch. Record SHA-256/size/source/target versions, then set the final mode to the source mode intersected with `0600` and fsync the file. Publish `.litestack-backup-v<source>-<UTC>-<pid>.sqlite3` with same-directory `File.link(partial, final)` so an existing destination is never replaced. Fsync the parent directory, unlink the partial name, and fsync again. If hard-link no-replace publication, directory fsync, or reliable local locking is unsupported, raise `Litestack::BackupPublicationError` and fail closed before mutation; network/cross-filesystem paths receive no recoverability guarantee. Never auto-delete a published backup.

Run ordered steps under the outer transaction with a savepoint per step; after `ROLLBACK TO`, release the savepoint and fail the whole upgrade. Use explicit begin/commit handling because commit may return `BUSY`; on every begin-or-later error, roll back when `transaction_active?`. Verify user version, full integrity, foreign keys, and component semantics before commit. The same protected seam wraps Litesearch `WRITABLE_SCHEMA`, rebuild, drop, and field-removal paths; keep writable schema enabled for the minimum statements and always execute `PRAGMA writable_schema=RESET` in `ensure`. On failure, preserve the original path and report any already published snapshot. Emit structured `migration.start`, `backup.created`, `step.completed`, `migration.succeeded`, and `migration.failed` events through the configured logger and Active Support notifications when available; payloads contain component, source/target version, step, duration, backup basename/checksum/size, and error class, but no row values, bind data, or absolute path by default.

**Patterns:** Extract the version loop currently in `Liteconnection#create_connection` into one focused object; do not introduce a general ORM migration DSL.

**Test scenarios:**
- [ ] Happy path: an additive multi-version schema upgrades in order and preserves rows.
- [ ] Nil/empty input: an already-current file performs no writes or backup.
- [ ] Error path: invalid YAML/version gaps and injected SQL failures raise named errors and preserve the source.
- [ ] Error path: forbidden transaction/VACUUM/journal SQL is rejected during preflight before a write transaction.
- [ ] Edge case: a destructive step creates and verifies a backup before mutation.
- [ ] Edge case: a database with live WAL content produces a snapshot containing committed WAL rows and no uncommitted rows.
- [ ] Edge case: static disk/permission preflight fails before the transaction; actual backup I/O failure inside the write transaction occurs before schema SQL, rolls back, and removes every unpublished partial.
- [ ] Edge case: a concurrent writer or second migrator times out with `MigrationBusyError` and neither source nor backup is changed.
- [ ] Edge case: an idle pre-upgrade process is treated as an operator quiescence violation in documentation because no cooperative lock can prove it is absent.
- [ ] Edge case: a failing Litesearch rebuild restores searchable pre-change content and retains its verified snapshot.
- [ ] Edge case: using A as a backup source fails the topology contract, while independent B-to-C backup succeeds under A's lock.
- [ ] Edge case: backup `BUSY`/`LOCKED` retries are bounded, fatal status codes never publish, and `finish`/connection cleanup happens exactly once.
- [ ] Edge case: an index inconsistency that passes `quick_check` fails full verification; foreign-key violations and Litesearch semantic mismatches also block publication.
- [ ] Edge case: `writable_schema` resets after an injected exception, commit-busy rolls back explicitly, and a destination collision is never overwritten.

**Verification:** `bundle exec ruby -Itest test/test_schema_migrator.rb` and `bundle exec ruby -Itest test/test_litesearch_schema_migration.rb` assert three-connection topology, status handling, lock exclusion, version, content/search results, full integrity/foreign keys, backup checksum/size, no-replace publication, failure recovery, handle cleanup, and absence of partial schema objects or required WAL/journal sidecars.

**Planning-time unknowns:** None; snapshots use the documented version/time/PID sibling name, are private before the first byte is written, and are retained until explicitly removed by the operator. Migration documentation requires stop-the-world deployment for old processes because only upgraded processes honor the advisory lock, and limits the recoverability promise to local filesystems with reliable locking, fsync, and same-filesystem hard-link publication.

### Unit 10: Published 0.4.3 Durable Data Fixtures

**Goal:** Prove forward compatibility from the latest published 0.4.x gem data format across every durable component.

**Requirements trace:** R4, R11, R13

**Dependencies:** Unit 9.

**Files:**
- `test/fixtures/v0_4_3/manifest.yml` — record source gem, Ruby/sqlite versions, creation commands, record expectations, and checksums.
- `test/fixtures/v0_4_3/litedb.sqlite3` — published-version relational fixture.
- `test/fixtures/v0_4_3/litejob.sqlite3` — queued/retry/scheduled job fixture.
- `test/fixtures/v0_4_3/litesearch.sqlite3` — indexed searchable data fixture.
- `test/fixtures/v0_4_3/litekd.sqlite3` — typed key-data fixture.
- `test/fixtures/v0_4_3/litemetric.sqlite3` — metric/event fixture.
- `test/test_upgrade_from_0_4_3.rb` — copy, open/upgrade, and assert every fixture.

**Approach:** Generate fixtures once using the published litestack 0.4.3 gem in an isolated environment, never using modernization code. Commit immutable small databases plus a reproducibility manifest. Tests copy each fixture to a temporary directory, verify the pre-upgrade checksum, open it through new code, assert semantic records/counts/search results/jobs/typed values/metrics, and exercise an injected failure on a disposable copy.

**Patterns:** Use Minitest temporary-directory patterns and real SQLite artifacts rather than mocked schema hashes.

**Test scenarios:**
- [ ] Happy path: all five fixture types open/upgrade and retain their manifest-defined semantic content.
- [ ] Nil/empty input: an empty but valid 0.4.3 durable database remains valid.
- [ ] Error path: a corrupted copy fails preflight before any source mutation.
- [ ] Edge case: tests never modify the committed fixture checksum.

**Verification:** `bundle exec ruby -Itest test/test_upgrade_from_0_4_3.rb` passes and a post-test checksum comparison matches `manifest.yml` exactly.

**Planning-time unknowns:** None; 0.4.3 is the latest published version and is a required historical source.

### Unit 11: Pre-Modernization 0.4.5 Durable Data Fixtures

**Goal:** Prove forward compatibility from the repository's immediate pre-modernization 0.4.5 data format.

**Requirements trace:** R4, R11, R13

**Dependencies:** Unit 9.

**Files:**
- `test/fixtures/v0_4_5/manifest.yml` — record source commit `e598e1b`, environment, content expectations, and checksums.
- `test/fixtures/v0_4_5/litedb.sqlite3` — pre-modernization relational fixture.
- `test/fixtures/v0_4_5/litejob.sqlite3` — pre-modernization job fixture.
- `test/fixtures/v0_4_5/litesearch.sqlite3` — pre-modernization search fixture.
- `test/fixtures/v0_4_5/litekd.sqlite3` — pre-modernization key-data fixture.
- `test/fixtures/v0_4_5/litemetric.sqlite3` — pre-modernization metric fixture.
- `test/test_upgrade_from_0_4_5.rb` — copy, upgrade, and semantically verify every fixture.

**Approach:** Generate the second fixture set from commit `e598e1b` in an isolated worktree/environment so current unmodified code, not planned code, creates it. Use the same manifest/test contract as Unit 10. This covers unreleased users tracking master and resolves the ambiguity between published 0.4.3 and repository version 0.4.5.

**Patterns:** Mirror Unit 10's immutable fixture and semantic assertion structure so differences between sources remain explicit.

**Test scenarios:**
- [ ] Happy path: all five 0.4.5 fixture types retain semantic content after open/upgrade.
- [ ] Nil/empty input: an empty current-format durable file remains a no-op upgrade.
- [ ] Error path: an injected migration failure leaves the copied source usable and reports backup state.
- [ ] Edge case: committed source fixtures remain byte-for-byte unchanged after tests.

**Verification:** `bundle exec ruby -Itest test/test_upgrade_from_0_4_5.rb` passes with manifest checksum and semantic assertions.

**Planning-time unknowns:** None; commit `e598e1b` is the authoritative pre-modernization implementation source.

### Unit 12: Built-Gem Rails 8.1 Application Smoke Test

**Goal:** Prove the packaged gem works end to end in a clean Rails 8.1 application rather than only on the repository load path.

**Requirements trace:** R2, R4–R12, R14, R18

**Dependencies:** Units 4–11.

**Files:**
- `test/integration/rails81_app_test.rb` — orchestrate build/install/app generation and assert end-to-end scenarios.
- `test/support/rails_app_builder.rb` — create an isolated Rails app and run commands with unbundled environment handling.
- `test/fixtures/rails81/expected_database.yml` — define required generator database postconditions.
- `test/fixtures/rails81/expected_cable.yml` — define required generator cable postconditions.
- `Rakefile` — expose an `integration:rails81` task and include it in full verification.

**Approach:** Build the gem, install it into an isolated gem home, generate a minimal Rails 8.1 app, add the built artifact (not `path:`), run Bundler, execute the Litestack generator, and boot/migrate/use each Rails integration. Use subprocess timeouts and capture named stdout/stderr artifacts on failure. Run two application shutdown cycles and command smoke tests. Keep network use outside the test after dependencies are cached.

**Patterns:** Use Ruby `Dir.mktmpdir`, `Open3`, and Bundler's unbundled environment; follow the existing Minitest suite rather than introducing an external system-test framework.

**Test scenarios:**
- [ ] Happy path: build/install/generate/boot/migrate/CRUD/cache/job/cable/dbconsole-dispatch all succeed.
- [ ] Nil/empty input: a minimal Rails app with optional frameworks disabled skips unavailable integration cleanly.
- [ ] Error path: generator or child command failure reports command, exit status, and captured output without leaving processes.
- [ ] Edge case: the app shuts down twice without statement/thread errors and rerunning the generator is idempotent.
- [ ] Edge case: installed gem loading succeeds with repository `lib/` removed from `$LOAD_PATH`.

**Verification:** `bundle exec rake integration:rails81` exits zero and logs exact Ruby/Rails/sqlite/Litestack versions plus successful assertions for every Rails-facing component.

**Planning-time unknowns:** None; CI verifies dbconsole adapter dispatch/argv with an injected executable seam and does not require a system sqlite3 CLI.

### Unit 13: Supported-Range CI and Package Gate

**Goal:** Turn both support boundaries, the exact target, and the latest-supported Ruby 4/Rails 8 contracts into blocking, reproducible gates and make future-version checks honest.

**Requirements trace:** R1–R4, R12–R15

**Dependencies:** Units 1, 2, 12, 14, and 15.

**Files:**
- `.github/workflows/ruby.yml` — replace the Rails 7 matrix with five supported-range combinations plus delivery and warning-only jobs.
- `Rakefile` — add package verification composition used locally and in CI.
- `litestack.gemspec` — narrow packaged files and correct release metadata.
- `gemfiles/rails81_min.gemfile` — pin Rails 8.1.0 for the supported lower-bound job.
- `gemfiles/rails8_latest.gemfile` — resolve the latest released supported Rails 8.x and optionally Rails main for non-blocking warning runs.
- `scripts/verify_package.rb` — inspect gem contents/metadata and perform isolated install/require/executable smoke.
- `bin/liteboard` — provide deterministic help/start failure behavior for package smoke tests.

**Approach:** Add five blocking combinations: Ruby 4.0.0 + Rails 8.1.0 for the declared floor, Ruby 4.0.5 + Rails 8.1.3 for the exact target, latest released Ruby 4.x + latest Rails 8.x, Ruby 4.0.0 + latest Rails 8.x, and latest Ruby 4.x + Rails 8.1.0. Every combination resolves dependencies and runs the full suite; exact/latest delivery jobs also run Standard, the slower built-gem app test, and artifact inspection/install. This boundary matrix prevents a diagonal-only green build from hiding either a new-Ruby/old-Rails or old-Ruby/new-Rails failure. Ruby head/Rails main remain explicitly allowed-failure scheduled checks, not support claims. Update GitHub actions to maintained immutable versions/SHAs. Restrict gem contents to runtime, license/readme/changelog, and intentional executables; exclude tests, stale locks, scripts, and benchmarks unless deliberately shipped. Exercise the verified Liteboard Rack app through the packaged executable and name startup/rendering failures.

**Patterns:** Preserve a single GitHub Actions workflow and Bundler gem tasks, with local Rake tasks matching CI commands exactly.

**Test scenarios:**
- [ ] Happy path: exact-target CI runs resolution, tests, style, build, package inspection, install, executable, and Rails app smoke.
- [ ] Happy path: minimum, exact, latest, minimum-Ruby/latest-Rails, and latest-Ruby/minimum-Rails pairs resolve and complete their blocking suites without relaxing dependency bounds.
- [ ] Nil/empty input: package inspection rejects an empty/missing artifact with a clear message.
- [ ] Error path: an unintended file or wrong Ruby/Rails metadata causes the package job to fail.
- [ ] Edge case: Rails main/Ruby head failures are visible but do not mark the supported target green or red incorrectly.

**Verification:** Every blocking workflow command is reproducible locally through `bundle exec rake verify`; `scripts/verify_package.rb` installs into a new temporary gem home and loads all public components.

**Planning-time unknowns:** Deferred to Planning — pin action SHAs to the maintained releases current at implementation time; record update provenance in the workflow comments.

### Unit 14: Safe and Accessible Liteboard Shell

**Goal:** Make Liteboard a valid Rack 3 application with safe rendering, explicit states, and an accessible responsive shell on Ruby 4.

**Requirements trace:** R1, R4, R13, R14, R16, R18

**Dependencies:** Units 2, 3, and 9.

**Files:**
- `lib/litestack/liteboard/liteboard.rb` — provide explicit routing/status/content types, safe parameters/rendering, and named failures.
- `lib/litestack/liteboard/views/layout.erb` — add semantic landmarks, labels, focus/responsive/reduced-motion styles, and script-loading fallbacks.
- `lib/litestack/liteboard/views/index.erb` — render a useful first-use/no-metrics state and accessible topic summaries.
- `lib/litestack/liteboard/views/topic.erb` — label search/sort controls and expose table/chart meaning without color alone.
- `lib/litestack/liteboard/views/event.erb` — label search/sort controls and expose event table/chart meaning.
- `lib/litestack/liteboard/assets/liteboard.css` — replace remote/inline presentation with responsive, focus-visible, reduced-motion local styles.
- `lib/litestack/liteboard/assets/liteboard.js` — provide dependency-free progressive chart enhancement from parsed JSON without inline script or `eval`.
- `test/test_liteboard.rb` — verify Rack, security, empty/error, keyboard/semantic, and no-JavaScript contracts.

**Approach:** Return a valid `[status, headers, body]` for every route, including 404 and 400 states, and set HTML content type plus `Content-Security-Policy`, `X-Content-Type-Options`, and referrer/frame protections. Replace broad rendering rescues and nil route returns with named `Liteboard::BadRequestError`/`RenderError` handling and visible recovery messages. Enable consistent HTML escaping for template values, encode URL segments, replace JavaScript `eval` with `JSON.parse` over safely encoded data, and test hostile metric/search values. Remove remote scripts, styles, fonts, inline script, and inline style; serve the two packaged assets with fixed content types and a self-only CSP so Liteboard works offline without mutable CDN code. Add `<header>`, labeled `<nav>`, `<main>`, `<footer>`, visible focus, `aria-current`, explicit form labels, sort text/`aria-sort`, reduced-motion handling, responsive layout, loading/failure/no-JavaScript feedback, and a text/table fallback for charts. Local JavaScript may progressively enhance a chart, but HTML remains authoritative.

**Patterns:** Retain the existing small Rack proc, Tilt/Erubi templates, and Litemetric queries; improve the shared shell and rendering seam instead of adding a frontend framework.

**Test scenarios:**
- [ ] Happy path: index/topic/event routes return escaped HTML, correct headers, semantic landmarks, labels, and keyboard-visible controls.
- [ ] Nil/empty input: a fresh metrics database displays a named no-data state and next action instead of blank charts/tables.
- [ ] Error path: invalid route/query/render data returns a valid 400/404/500 response with a recovery message and structured log event.
- [ ] Edge case: hostile HTML/JavaScript in topic, event, key, and search values is rendered as text and never executed.
- [ ] Edge case: disabling/failing external JavaScript still leaves readable data tables and status text.
- [ ] Edge case: CSP forbids inline/remote execution while packaged CSS/JavaScript assets load with correct MIME types offline.

**Verification:** `bundle exec ruby -Itest test/test_liteboard.rb` validates Rack 3 responses, security headers, local assets, and HTML semantics with no network; a browser smoke at narrow/wide viewports and keyboard-only navigation confirms visible focus, readable fallback data, and no console CSP/`eval`/render errors.

**Planning-time unknowns:** Deferred to Planning — use the lightest HTML assertion/accessibility checker compatible with Ruby 4; do not add a browser framework solely for static semantics if parsed HTML assertions cover them.

### Unit 15: Accessible Liteboard Component Pages

**Goal:** Give each component dashboard complete success, empty, partial, and failure states with non-visual data equivalents.

**Requirements trace:** R4, R13, R16, R18

**Dependencies:** Unit 14.

**Files:**
- `lib/litestack/liteboard/views/litecache.erb` — add semantic metric labels, zero-safe calculations, fallback tables, and empty states.
- `lib/litestack/liteboard/views/litedb.erb` — add semantic metric labels, explicit missing snapshots, and accessible read/write data.
- `lib/litestack/liteboard/views/litejob.erb` — add queue/job empty/draining/error states and accessible timing/count data.
- `lib/litestack/liteboard/views/litecable.erb` — add subscription/message empty states and accessible channel data.
- `test/test_liteboard_components.rb` — verify each component across full/empty/partial/corrupt snapshot inputs.

**Approach:** Remove rescue-as-default expressions from templates; normalize view models in Ruby so templates receive explicit values/state. Use headings in order, metric names with units, table captions and scoped headers, textual chart summaries, and visible empty/partial/error messages. Sorting and trends must not rely only on color or icons. Keep existing layout and chart library as progressive enhancement.

**Patterns:** Reuse Unit 14's escaped renderer, state components, and fallback markup; do not create a component framework.

**Test scenarios:**
- [ ] Happy path: each of four component pages renders named totals, units, accessible tables, and chart summaries.
- [ ] Nil/empty input: absent events/snapshots render component-specific empty states without division/nil errors.
- [ ] Error path: malformed or partial snapshot data renders a named partial/error state and logs the source failure.
- [ ] Edge case: zero reads/writes/jobs/messages produce meaningful zero metrics without `NaN`, infinity, or broad rescue.

**Verification:** Component tests parse rendered HTML for headings, captions, scoped headers, state messages, units, and escaped values; keyboard/no-JavaScript browser smoke covers one full and one empty component page.

**Planning-time unknowns:** None; charts are progressive enhancement and the HTML data representation is authoritative.

### Unit 16: Ruby 4 Developer Script Harness

**Goal:** Make maintenance and diagnostic scripts finite, relocatable, dependency-declared, and documented on Ruby 4.

**Requirements trace:** R1, R4, R17

**Dependencies:** Units 1–3.

**Files:**
- `scripts/build_metrics.rb` — use supported requires/options and deterministic output paths.
- `scripts/test_cable.rb` — add bounded duration, cleanup, and working-directory independence.
- `scripts/test_job_retry.rb` — add bounded execution and explicit result assertions.
- `scripts/test_metrics.rb` — add bounded execution and cleanup.
- `scripts/README.md` — document prerequisites, commands, expected output, and cleanup.
- `samples/ultrajob.yaml` — align sample configuration with current option names/paths.
- `Rakefile` — add non-default script smoke tasks with timeouts.

**Approach:** Resolve paths relative to each script, use `OptionParser` for duration/output where useful, replace permanent sleeps with bounded waits and assertions, and close every component in ensure blocks. Declare optional script-only dependencies in documented Bundler groups rather than loading undeclared gems accidentally.

**Patterns:** Reuse component public APIs and the new lifecycle contract; keep scripts as small executable examples rather than a new CLI framework.

**Test scenarios:**
- [ ] Happy path: each script finishes within its documented timeout and verifies its intended behavior.
- [ ] Nil/empty input: no arguments select safe finite defaults.
- [ ] Error path: missing optional dependency/configuration produces an actionable non-zero error.
- [ ] Edge case: scripts run successfully from outside the repository root and clean temporary databases/workers.

**Verification:** `bundle exec rake scripts:smoke` exits zero under Ruby 4 and process/file checks show no leaked workers or unexpected repository files.

**Planning-time unknowns:** None; scripts remain diagnostic and non-default.

### Unit 17: Standalone Benchmark Harness

**Goal:** Make standalone cache/job/queue benchmarks reproducible and safe to smoke-test on Ruby 4.

**Requirements trace:** R1, R4, R17

**Dependencies:** Units 1, 2, and 16.

**Files:**
- `BENCHMARKS.md` — document reproducible environment, commands, sampling, and result provenance.
- `bench/Gemfile` — declare benchmark-only dependencies and the local gem.
- `bench/bench.rb` — provide validated counts, warmup, timing, environment output, and cleanup helpers.
- `bench/bench_cache_raw.rb` — use the shared finite harness and temporary paths.
- `bench/bench_jobs_raw.rb` — use the shared finite harness and drain/close workers.
- `bench/bench_queue.rb` — create/clean its database directory safely.
- `bench/skjob.rb` — isolate optional Sidekiq comparison loading.
- `bench/uljob.rb` — align Litestack job comparison with current APIs.

**Approach:** Separate a fast smoke mode from performance runs, validate iteration counts instead of allowing `nil.to_i == 0`, record commit/Ruby/Rails/sqlite/platform data, and require warmups plus multiple samples for published numbers. Store all databases under temporary or explicit output directories and close them.

**Patterns:** Retain the existing benchmark scripts and comparison classes, consolidating only repeated setup/timing/cleanup in `bench/bench.rb`.

**Test scenarios:**
- [ ] Happy path: each standalone benchmark completes a small smoke count and prints environment/results.
- [ ] Nil/empty input: omitted count uses the documented nonzero default.
- [ ] Error path: invalid/negative count or missing comparison dependency fails before creating data.
- [ ] Edge case: repeated runs do not reuse stale queue/cache databases unless explicitly requested.

**Verification:** From `bench/`, the benchmark bundle resolves and every standalone script passes smoke mode; documented performance mode emits machine-readable sample data.

**Planning-time unknowns:** Deferred to Planning — performance numbers are refreshed only after compatibility code stabilizes; no fixed performance threshold is invented before measurement.

### Unit 18: Rails Benchmark Paths

**Goal:** Make Rails cache/job benchmarks execute against the supported Rails 8.1 contract without serving as unverified compatibility claims.

**Requirements trace:** R2, R4, R7, R17

**Dependencies:** Units 4–7 and 17.

**Files:**
- `bench/bench_cache_rails.rb` — benchmark Litecache through Rails 8.1 cache APIs with cleanup.
- `bench/bench_jobs_rails.rb` — benchmark Litejob through Rails 8.1 Active Job APIs with bounded drain.
- `bench/rails_job.rb` — align job definitions/serialization with Active Job 8.1.
- `bench/README.md` — document Rails/standalone benchmark setup and smoke/performance modes.
- `BENCHMARKS.md` — replace Rails 7-era claims only with newly measured, versioned results.
- `Rakefile` — expose non-blocking benchmark smoke tasks.

**Approach:** Run Rails benchmarks under the exact target bundle, reuse Unit 17's timing/environment schema, and avoid endless sleeps. Treat benchmark smoke as functional CI evidence only; keep expensive performance measurements manual and provenance-rich.

**Patterns:** Preserve existing Rails benchmark entry points and job classes, using supported adapters rather than direct internal queues.

**Test scenarios:**
- [ ] Happy path: Rails cache and job benchmarks complete smoke mode on Rails 8.1.3.
- [ ] Nil/empty input: safe defaults run a finite nonzero workload.
- [ ] Error path: adapter boot or drain timeout fails with captured queue/cache state.
- [ ] Edge case: benchmark shutdown leaves no Active Job/Litestack workers alive.

**Verification:** `bundle exec rake bench:smoke` exits zero on the exact target; any published results name commit and complete environment metadata.

**Planning-time unknowns:** None beyond Unit 17's deferred re-measurement decision.

### Unit 19: Support, Migration, and Contributor Documentation

**Goal:** Make every user/developer instruction consistent with the breaking Ruby 4/Rails 8.1 support contract and actual verified commands.

**Requirements trace:** R1, R2, R4, R11, R14–R17

**Dependencies:** Units 12–18.

**Files:**
- `README.md` — publish support matrix, correct component/configuration examples, and link migration/contributor docs.
- `CHANGELOG.md` — describe modernization changes and breaking support removals pending final version.
- `CAVEATS.md` — update Ruby 4/sqlite3 concurrency, deployment, lifecycle, and recovery caveats.
- `FILESYSTEMS.md` — document durable/ephemeral files, backup placement, and filesystem guarantees.
- `ROADMAP.md` — mark completed test/CI compatibility work and keep unrelated future work separate.
- `docs/MIGRATING_TO_RUBY4_RAILS81.md` — provide preflight, backup, generator, Solid service, validation, and recovery steps.
- `CONTRIBUTING.md` — document exact setup, tests, style, integration, fixtures, benchmarks, and package verification.
- `template.rb` — fix repository reference and constrain the application template to the supported release/branch behavior.

**Approach:** Derive every command from passing local/CI tasks. Clearly distinguish durable versus rebuildable data, supported versus warning-only versions, automatic generator behavior versus optional Solid Cache/Queue cleanup, and upgrade versus unsupported downgrade. The migration runbook requires all old Litestack processes/workers to stop before preflight, forbids rolling mixed-version access to a durable file, explains `MigrationBusyError`, checks free space/permissions/full integrity/foreign keys, identifies retained backups and checksums, and gives rollback/restart validation steps. `FILESYSTEMS.md` limits the recoverability promise to local filesystems with reliable advisory/SQLite locks, fsync, directory fsync, and same-filesystem hard-link publication; network filesystems, aliases, and cross-volume temporary paths are rejected or explicitly outside the power-loss guarantee. Correct existing API/file-name/example errors and remove unverified performance claims rather than carrying them forward.

**Patterns:** Keep focused top-level project docs and add one migration guide plus one contributor guide; do not create a documentation site.

**Test scenarios:**
- [ ] Happy path: a new user can install/configure/boot from README commands and an upgrader can complete the migration checklist.
- [ ] Nil/empty input: standalone users without Rails receive a clear applicable subset rather than Rails-only steps.
- [ ] Error path: migration recovery instructions cover failed preflight, backup, schema step, and application smoke.
- [ ] Error path: concurrent or unquiesced deployment instructions stop before mutation and explain how to identify/retry the lock owner safely.
- [ ] Edge case: every referenced path/command/version exists and matches package/CI metadata.

**Verification:** Run link/path/command snippet checks plus a manual diff against package metadata; the Rails app smoke uses the same documented generator and validation commands.

**Planning-time unknowns:** None; exact release number placeholders remain only until Unit 20 and are mechanically replaced there.

### Unit 20: Breaking Release Readiness

**Goal:** Produce an internally consistent, install-tested 1.0.0 release candidate without publishing it externally.

**Requirements trace:** R1–R4, R11–R16

**Dependencies:** Units 13 and 19 (and transitively all earlier units).

**Files:**
- `lib/litestack/version.rb` — set the release candidate version to 1.0.0.
- `CHANGELOG.md` — finalize dated release notes and migration link.
- `litestack.gemspec` — finalize metadata and package file policy.
- `docs/MIGRATING_TO_RUBY4_RAILS81.md` — replace release placeholders and final compatibility notes.
- `test/test_release_metadata.rb` — assert version/changelog/gemspec/docs/package agreement.
- `Rakefile` — add a release-candidate dry-run task that never pushes.

**Approach:** Set version 1.0.0 once across authoritative sources. Build into a temporary output directory, inspect contents/metadata, install into a fresh gem home, run all public requires/executable help and the Rails application smoke, and emit checksums. Do not call `gem push`, create a tag, or publish a GitHub release as part of implementation without separate explicit authorization.

**Patterns:** Use Bundler's existing gem tasks and Unit 13's package verifier; add consistency assertions rather than a second release system.

**Test scenarios:**
- [ ] Happy path: release-candidate dry run builds, verifies, installs, and exercises the exact artifact successfully.
- [ ] Nil/empty input: missing release version/changelog section fails before build.
- [ ] Error path: metadata, packaged file, checksum, or documentation mismatch fails the dry run.
- [ ] Edge case: repository load paths are unavailable during installed-artifact smoke tests.

**Verification:** `bundle exec rake release:dry_run` exits zero, prints artifact checksum and exact support metadata, and leaves no tag/push/release side effect.

**Planning-time unknowns:** None; version 1.0.0 is confirmed, and external publication remains explicitly unauthorized by this plan.

## Dependency DAG

```text
U1 → U2 → U3 ─┬→ U4 ─┐
              ├→ U5  │
              ├→ U6  ├→ U8 ──────────┐
              └→ U7 ─┘                │
U2,U3 → U9 → U10,U11 ────────────────┘→ U12 ──────────┐
           └→ U14 → U15 ─────────────────────├→ U13 ─┐
U1,U2,U3 → U16 → U17 ─┬─────────────────────┐ │       │
U4,U5,U6,U7,U17 → U18 ─┘                         ├→ U19 ─┘
U12,U13,U14,U15,U16,U17,U18 ─────────────────────┘
U13,U19 → U20
```

## Requirements Coverage

| Requirement | Units |
|-------------|-------|
| R1 | 1–3, 13, 14, 16, 17, 19, 20 |
| R2 | 1, 4–8, 12, 13, 18–20 |
| R3 | 1, 13 |
| R4 | 2–20 |
| R5 | 4, 12 |
| R6 | 5, 12 |
| R7 | 6, 12, 18 |
| R8 | 7, 12 |
| R9 | 4, 8, 12 |
| R10 | 3, 5–7, 9, 12 |
| R11 | 9–12, 19, 20 |
| R12 | 8, 12, 13 |
| R13 | 2, 10, 11, 13–15 |
| R14 | 1, 2, 12–14, 19, 20 |
| R15 | 1, 13, 19, 20 |
| R16 | 8, 14, 15, 19, 20 |
| R17 | 16–19 |
| R18 | 3–9, 12, 14, 15 |

## Engineering Review Record

### 1. Scope Challenge

The plan holds the confirmed product scope: all existing public components, Ruby 4/Rails 8.1 compatibility, durable upgrade safety, delivery evidence, and a 1.0.0 release candidate. The review did not add a new service, UI feature, compatibility shim, downgrade path, Rails 7 path, performance promise, or publication action. Minimum-version proof, migration locking, Litesearch destructive-change protection, Sequel verification, and Liteboard CSP/local assets are structural work required to make already accepted support, safety, integration, and UI claims true.

### 2. Architecture

The gem remains standalone-first. Rails version enforcement runs only at Railtie/adapter entry points; it does not create a Rails runtime dependency. Framework adapters stay thin and are tested against their public host interfaces. Scheduler selection is thread-local/current-state based, pooled resources have one close boundary, and worker shutdown never closes storage under a live task. Durable SQL YAML evolution and Litesearch destructive schema work share one migrator/protection boundary. Upgrade correctness requires an operator quiescence precondition, a process advisory lock, a bounded database write lock, separate migration/read-source/backup-target connections, a fully verified no-replace snapshot publication, one outer transaction with per-step savepoints, and post-migration integrity/semantic checks. No lock is claimed to detect an idle old binary that does not participate in the protocol.

### 3. Code Quality

New failure modes use named errors (`UnsupportedFrameworkVersionError`, `ClosedError`, `ShutdownTimeoutError`, `MigrationBusyError`, migration/backup/publication errors, and Liteboard request/render errors) rather than broad rescues. Packaged migration YAML is safely parsed and structurally validated, backup integer status codes are exhaustively classified, and every native handle has exact-once cleanup. Structured events have bounded, non-secret payloads. Liteboard removes `eval`, remote mutable assets, inline executable code, and rescue-as-default view expressions; its local assets and self-only CSP keep the packaged executable deterministic offline. Existing style debt may be narrowly excluded, but every changed production file and all new tests are inside the Ruby 4 Standard gate.

### 4. Test Review

Legend: `●` explicit new/expanded contract, `○` existing suite retained under the corrected harness, `—` intentionally not applicable.

| Public surface | Standalone/Ruby 4 | Framework contract | Durable 0.4.3/0.4.5 | Built/package proof |
|----------------|-------------------|--------------------|---------------------|---------------------|
| Litedb | ● Unit 4 | ● Rails AR + dbconsole, Unit 4 | ● Units 10–11 | ● Units 12–13 |
| Litecache | ● Unit 5 | ● Rails cache, Unit 5 | — rebuildable | ● Units 12–13 |
| Litejob | ● Unit 6 | ● Active Job, Unit 6 | ● Units 10–11 | ● Units 12–13 |
| Litecable | ● Unit 7 | ● Action Cable, Unit 7 | — rebuildable | ● Units 12–13 |
| Litesearch | ○ full suite + ● Unit 9 | ● AR/Sequel search, Unit 4 | ● Units 10–11 | ● Unit 13 public require |
| Litemetric | ● Unit 3 | — no Rails adapter | ● Units 10–11 | ● Units 14–15 and package |
| LiteKD | ○ `test/test_litekd.rb` | — no Rails adapter | ● Units 10–11 | ● Unit 13 public require |
| Liteboard | ● Units 14–15 | ● Rack 3 contract | — reads metrics | ● Unit 13 executable |
| Shared lifecycle | ● Unit 3 thread/fiber/pool/fork/exit matrices | ● Units 4–8, 12 | ● backup/status/rollback paths | ● double shutdown |

The harness targets 100% line/branch coverage for new compatibility files and materially changed branches while preventing aggregate regression. Deliberately unclaimed areas are downgrade behavior, Rails 7/Rails 9 support, cross-browser automation beyond the named browser smoke, and pre-measurement performance thresholds. Every accepted public surface has a success, nil/empty, error, and edge path at the nearest useful layer.

## Phase 6 Deepening Record

Confidence-gap selection used the prescribed score (`+1` per gap, `+2` blocking unknown, `+3` critical path). Unit 9 durable migration scored 6; Units 4–8/13 Rails contracts and support boundaries scored 4; Units 2–3 Ruby scheduler/lifecycle scored 4. Other sections scored below the selection threshold and were not expanded.

| Selected section | Authoritative finding | Plan decision after research |
|------------------|-----------------------|------------------------------|
| SQLite migration/backup | A connection holding the write transaction cannot safely serve as the backup source (`LOCKED`/`BUSY`); `Backup#step` returns status integers; `quick_check` omits index-content checks; `writable_schema` misuse can corrupt a database. | Use A/B/C connection roles, bounded status handling, exact-once finish, full integrity + foreign-key + semantic checks, no-replace hard-link publication, explicit commit/rollback, and guaranteed writable-schema reset. |
| Rails 8.1 contracts | Active Job transaction deferral is job-class/Active Record behavior, not an adapter hook; AR's inherited connect calls class `new_client`; cache multi-read receives original names; adapter support needs cross-corner CI. | Correct Unit 4–8 seams and tests, set provider IDs explicitly, preserve original cache keys, compose Action Cable through Base/event loop, remove obsolete Railtie config, and gate five version combinations. |
| Ruby 4 scheduler/lifecycle | `Fiber.scheduler` is per-thread and Ruby clears it after fork; Ruby 4 adds scheduler hooks; current sleepers and pool close cannot meet the stated shutdown guarantee. | Remove global backend caching, implement the exercised Ruby 4 hook contract, add wakeable/waitable task handles, close every pool resource, keep timeout retryable, neutralize fork/exit callbacks, and prove behavior in thread/fork/subprocess matrices. |

Primary references: [SQLite transactions](https://www.sqlite.org/lang_transaction.html), [online backup API](https://www.sqlite.org/c3ref/backup_finish.html), [integrity pragmas](https://www.sqlite.org/pragma.html#pragma_integrity_check), [Rails 8.1.3 SQLite adapter](https://github.com/rails/rails/blob/v8.1.3/activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb), [Rails 8.1.3 Active Job transaction behavior](https://github.com/rails/rails/blob/v8.1.3/activejob/lib/active_job/enqueue_after_transaction_commit.rb), [Rails 8.1.3 cache Store](https://github.com/rails/rails/blob/v8.1.3/activesupport/lib/active_support/cache.rb), [Ruby 4 Fiber scheduler interface](https://docs.ruby-lang.org/en/4.0/Fiber/Scheduler.html), and the [Ruby 4.0 release notes](https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/).

## Quality Bar Checklist

- [x] Every unit has a requirements trace.
- [x] Dependencies form a DAG with no cycles.
- [x] Every unit has at least three named test scenarios, including error/edge behavior.
- [x] No unit touches more than eight files.
- [x] No unit introduces more than two new abstractions; Unit 1 adds one compatibility check, Unit 3 adds a lifecycle state machine plus one stop/wake handle seam, Unit 9 adds one migrator, and Unit 12 adds one app builder.
- [x] Every planning-time unknown is classified as `Resolve Before Planning` or `Deferred to Planning`.
- [x] Every Must Have requirement is covered by at least two verification layers where its risk warrants it.
- [x] Handoff completeness: implementation must choose mechanical details, but no component scope, support policy, data-loss policy, generator deletion behavior, or external publishing behavior remains to be invented.
