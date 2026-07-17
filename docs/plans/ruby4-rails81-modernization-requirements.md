# Ruby 4 and Rails 8.1 Modernization Requirements

**Version:** 1.0
**Status:** Draft
**Date:** 2026-07-17

## Problem Frame

Litestack's published metadata, development bundle, CI matrix, Rails integration tests, generator behavior, lifecycle handling, and release documentation were built around Ruby 3 and Rails 7. The core library can execute much of its existing test suite on Ruby 4.0.5 and Rails 8.1.3, but that result does not establish supported compatibility: the repository bundle cannot select the target Rails version, important Rails entry points are bypassed in tests, a real Rails application is not exercised, and shutdown and generated-configuration behavior have target-version failures.

The project needs a release-grade modernization rather than a ground-up rewrite. Compatibility must cover every public component, make Ruby 4 and Rails 8.1 the explicit supported baseline, preserve durable on-disk data through recoverable upgrades, and provide enough automated evidence that the gem can be built, installed, configured, run, shut down, and upgraded safely.

## Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| R1 | The gem MUST declare Ruby `>= 4.0` and MUST execute on the target Ruby 4.0.5 runtime without compatibility warnings caused by Litestack's own code or test doubles. | Must Have | Ruby versions below 4.0 are unsupported. |
| R2 | Rails integration MUST support Rails `>= 8.1` and `< 9`, with Rails 8.1.3 as the exact required verification target. | Must Have | Rails 7.2 and earlier are unsupported; Rails main/9 may be non-blocking early warning only. |
| R3 | The repository development bundle and target appraisal/Gemfile MUST resolve reproducibly on x86_64 Linux with Ruby 4.0.5, Rails 8.1.3, Bundler 4, and a Rails-compatible sqlite3 2.x release. | Must Have | Development dependency constraints and stale platform-specific locks must not prevent target testing. |
| R4 | All public components—Litedb, Litecache, Litejob, Litecable, Litesearch, Litemetric, LiteKD, Liteboard, and their Active Record, Active Job, Active Support, Action Cable, and Sequel integrations—MUST remain loadable and behaviorally verified on Ruby 4. | Must Have | A component may not be silently dropped to make the upgrade pass. |
| R5 | The Litedb Active Record adapter MUST use Rails 8.1's registered-adapter path and public connection contract for application boot, connection establishment, migrations/schema operations, CRUD, and dbconsole dispatch without test-only monkey patches. | Must Have | Rails 8 removed fallback discovery for unregistered adapters. |
| R6 | Litecache MUST conform to the Rails 8.1 cache-store contract for single and multi read/write, expiration, counters, conditional writes, serialization, and clear/cleanup behavior without globally forcing another cache format for the host application. | Must Have | Cache data is ephemeral and may be rebuilt during upgrade. |
| R7 | Litejob MUST conform to the Rails 8.1 Active Job adapter contract for immediate, asynchronous, scheduled, retried, transactional, named-queue, and graceful-stopping behavior. | Must Have | Adapter shutdown/stopping behavior must be observable and deterministic. |
| R8 | Litecable MUST conform to the Rails 8.1 Action Cable subscription-adapter contract for subscribe, broadcast, unsubscribe, channel prefixes, and idempotent shutdown. | Must Have | Cable data is ephemeral and may be rebuilt during upgrade. |
| R9 | The Railtie, install generator, configuration templates, and dbconsole integration MUST work in a freshly generated Rails 8.1 application without silently missing edits, overwriting unrelated multi-database configuration, or relying on copied Rails internals. | Must Have | Generated changes must be asserted in tests. |
| R10 | Connection, statement, worker, fork, scheduler, and `at_exit` lifecycle operations MUST be idempotent on Ruby 4 and sqlite3 2.x; repeated close/shutdown calls MUST NOT raise or leave background execution contexts running. | Must Have | Includes the observed closed-statement failure and Ruby 4 scheduler contract. |
| R11 | Existing durable data created by the current 0.4.x format for Litedb, Litejob, Litesearch, LiteKD, and Litemetric MUST open unchanged or upgrade without data loss. | Must Have | Upgrade performs preflight validation, uses transactional schema changes, creates a backup when a destructive transformation is necessary, and leaves the old file usable after failure; downgrade compatibility is not required. |
| R12 | Automated tests MUST include a real Rails 8.1 temporary application that installs the built gem and verifies generator output, boot, Active Record migration/CRUD, cache operations, Active Job execution, Action Cable messaging/shutdown, and command integration. | Must Have | Directly requiring adapter files is insufficient evidence. |
| R13 | The unit/integration suite MUST start coverage before project code loads, isolate global/process state, remove target-runtime warnings, and enforce an explicit line and branch coverage baseline that cannot regress. | Must Have | The initial threshold is set from a trustworthy full-suite measurement, then raised for changed compatibility paths. |
| R14 | CI MUST gate the exact Ruby 4.0.5 + Rails 8.1.3 target on dependency resolution, full tests, Standard, gem build, package-content inspection, temporary install, and executable smoke tests. | Must Have | Rails main/Ruby head checks may be allowed to fail and must not imply formal support. |
| R15 | The gem package and release metadata MUST be internally consistent: version, changelog, source/changelog URLs, supported versions, lock/platform data, and packaged files MUST match the release being built. | Must Have | The modernization is a breaking release; the exact version number remains a release decision. |
| R16 | README, migration guidance, generator usage, component examples, contributor setup, test commands, and release instructions MUST accurately describe Ruby 4/Rails 8.1 behavior, durable-data backup/recovery, unsupported versions, and replacement of Rails defaults such as Solid Cache/Queue where applicable. | Must Have | Examples must be executable or covered by smoke tests. |
| R17 | Benchmarks, scripts, and developer utilities SHOULD run from documented commands on Ruby 4 without relying on undeclared dependencies, missing directories, accidental infinite sleeps, or the caller's working directory. | Should Have | Performance re-benchmarking is required only where modernization changes a measured path. |
| R18 | Compatibility changes SHOULD prefer Rails/Ruby public APIs and existing Litestack component boundaries; any unavoidable internal API dependency MUST be isolated, documented, and covered by a focused contract test. | Should Have | No speculative framework abstraction layer. |

## Success Criteria

- `bundle install` and the target Rails 8.1 dependency definition resolve on Ruby 4.0.5/Bundler 4 without selecting Rails 7 components.
- The complete test suite and Standard check exit successfully on Ruby 4.0.5 with Rails 8.1.3 and sqlite3 2.x, with no Litestack-owned runtime warnings, failures, errors, or skips in required compatibility scenarios.
- A clean Rails 8.1 application can install the built gem, run the Litestack generator, boot, migrate and query Litedb, read/write Litecache, enqueue and perform Litejob work, exchange a Litecable message, run command smoke tests, and shut down twice without error.
- Each public component named in R4 has at least one Ruby 4 smoke or integration path, and each Rails-facing component has a Rails 8.1 contract test that does not depend on the existing Active Record connection-handler patch.
- Versioned 0.4.x fixture databases for every durable component named in R11 upgrade successfully with record/count/content assertions; an injected migration failure demonstrates rollback and preservation of the original file or backup.
- CI contains a blocking exact-target job covering tests, style, build, install, and smoke verification; optional future-version jobs are visibly non-blocking.
- The built gem declares Ruby `>= 4.0`, documents Rails `>= 8.1, < 9`, contains only intentional release files, and passes a fresh temporary installation smoke test.
- Release and migration documentation names all breaking support changes, backup/recovery behavior, Rails default-service replacement steps, and unsupported Ruby/Rails versions.

## Scope Boundaries

**In scope:**
- Ruby 4 syntax/runtime, stdlib/default-gem, scheduler, thread/fiber, fork, and shutdown compatibility.
- Rails 8.1 Active Record, Active Job, Active Support cache, Action Cable, Railtie, generator, configuration, and command integration.
- Every public Litestack component and Sequel integration on Ruby 4.
- Durable schema/data upgrade fixtures, preflight, transactional migration, backup, failure recovery, and migration documentation.
- Dependency definitions, test harness, coverage, CI, gem packaging, install smoke tests, developer scripts, documentation, and release readiness.

**Out of scope:**
- Support for Ruby versions below 4.0 or Rails versions below 8.1.
- A formal compatibility promise for Rails 9 or unreleased Rails/Ruby versions.
- Downgrading an upgraded durable database for use by an older Litestack release.
- A ground-up rewrite of working storage, search, queue, cache, metrics, or concurrency architecture.
- New product features unrelated to Ruby 4/Rails 8.1 compatibility or release safety.
- Broad style-only rewrites outside files touched by the modernization, except where required to restore the configured quality gate.

## Key Decisions

| Decision | Chosen | Rationale | Alternatives Considered |
|----------|--------|-----------|------------------------|
| Ruby support floor | Ruby `>= 4.0` | The modernization intentionally adopts the local Ruby 4 runtime and removes legacy syntax/tooling constraints. | Preserve Ruby 3.x compatibility. |
| Rails support band | Rails `>= 8.1, < 9` | Supports the requested Rails generation without making an unverified promise for the next major version. | Rails 8.1.x only; unbounded Rails `>= 8.1`; retain Rails 7.2. |
| Component scope | Every public component and integration | The requested outcome is a whole-project modernization, not a Rails boot shim. | Rails integration layer only; install/boot only. |
| Durable data policy | Recoverable forward upgrade | Protects user data while avoiding the much larger constraint of old-version downgrade compatibility. | Bidirectional compatibility; destructive reset. |
| Ephemeral data policy | Litecache and Litecable may be rebuilt | Cache and transient cable messages do not justify durable-format migration complexity. | Preserve every SQLite file. |
| Implementation strategy | Staged in-place modernization | Existing target-runtime tests show that core behavior is viable; staged changes minimize regression and isolate framework breakpoints. | Ground-up rewrite; compatibility-shim-only patch. |
| Release semantics | Breaking release | Dropping Ruby 3 and Rails 7 is an intentional compatibility break and must be communicated as such. | Patch/minor release without a breaking-version signal. |

## Outstanding Questions

| # | Question | Impact if Wrong | Owner |
|---|----------|-----------------|-------|
| Q1 | What release version will carry the breaking support floor (for example, 1.0.0 versus a pre-1.0 minor)? | Incorrect versioning can surprise existing users and weaken migration signaling. | Maintainer |
| Q2 | Which exact 0.4.x releases and fixture files represent supported durable-data upgrade sources? | Missing historical schemas could allow silent data loss despite green current-version tests. | Maintainer / implementation |
| Q3 | Should the Rails 8.1 generator remove or only supersede Solid Cache/Queue dependencies and generated configuration? | Over-aggressive mutation can damage an application; insufficient mutation leaves duplicate services and misleading setup. | Maintainer / implementation |
| Q4 | What trustworthy initial line and branch coverage thresholds should CI enforce after test loading is corrected? | A threshold set from the current invalid report will either provide false confidence or create arbitrary churn. | Implementation |
