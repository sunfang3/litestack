# Migrating to Litestack 1.0 (Ruby 4 + Rails 8.1)

Litestack **1.0.0** is a breaking release. It requires:

| | Supported | Unsupported |
|--|-----------|-------------|
| Ruby | `>= 4.0` (verified on 4.0.0 and 4.0.5) | Ruby 3.x and earlier |
| Rails (optional integrations) | `>= 8.1, < 9` (verified on 8.1.0 and 8.1.3) | Rails 7.x, 8.0.x, Rails 9+ |

Standalone components (`require "litestack"`) do not depend on Rails. Rails version checks run only when Railtie/adapters load and raise `Litestack::UnsupportedFrameworkVersionError` outside the supported band.

## Preflight checklist

1. **Stop all old Litestack processes and workers** (web, job runners, metrics). Mixed-version access to a durable SQLite file is unsupported.
2. Confirm free disk space for a full copy of each durable database.
3. Confirm write permissions on the directory holding durable files.
4. Note paths for: Litedb app DB, Litejob queue, Litesearch-backed DBs, LiteKD, Litemetric.
5. Ephemeral files (Litecache, Litecable) may be deleted and rebuilt; no format migration is required.

## Durable data upgrade

On first open with 1.0, durable components apply forward schema steps via `Litestack::SchemaMigrator`:

- Cooperative advisory lock + SQLite write lock (`MigrationBusyError` if busy).
- Preflight validation of SQL YAML and `PRAGMA user_version` (rejects `VACUUM`/transaction control).
- **Three-connection online backup** before destructive steps: migration connection A holds the write lock; independent read-only B is the backup source; exclusive-create C is the destination. Never uses A as the backup source.
- Snapshot verified with full `PRAGMA integrity_check` + `PRAGMA foreign_key_check`, then published via same-directory hard-link no-replace as `.litestack-backup-v<source>-<UTC>-<pid>.sqlite3`.
- Transactional steps with rollback on failure; original file remains usable.
- Backups are **never auto-deleted**. Recoverability is limited to local filesystems with reliable locks/fsync/hard-link (see `FILESYSTEMS.md`).

### Recovery

| Failure | What to do |
|---------|------------|
| `MigrationBusyError` | Ensure only one migrator; stop writers; retry |
| Step SQL failure | File rolled back; investigate logs; retry after fix |
| App will not open upgraded file | Restore from `.litestack-backup-v...sqlite3` snapshot; file was retained |
| Need old Litestack | Downgrade is **not** supported on upgraded files — restore backup and stay on previous version |

## Rails application steps

```bash
bundle update litestack
# ensure Gemfile has ruby >= 4.0 and rails >= 8.1
bin/rails generate litestack:install
bin/rails db:prepare
```

Optional Chinese/Pinyin FTS and vector search need **app-local** native libraries
(`libsimple`, `vectorlite`). They are **not** installed by the generator. See
**[RAILS_FULL_STACK.md](RAILS_FULL_STACK.md)**.

### Solid Cache / Solid Queue

The install generator **supersedes configuration** (cache store → `:litecache`, Active Job → `:litejob`) but **never** auto-deletes:

- `solid_cache` / `solid_queue` gems
- their migrations
- arbitrary Gemfile content

Optional cleanup (manual only):

1. Remove Solid gems from the Gemfile and `bundle install`
2. Remove unused Solid migrations/config if no longer needed
3. Confirm production uses Litecache/Litejob

### Generator safety

- Multi-database `database.yml` keeps unrelated DB entries when possible.
- Re-running the generator is idempotent for already-configured keys.
- Unrecognized configs fail visibly rather than silent no-ops.

## Validation

```bash
bundle exec rake test
bundle exec rake standard
bundle exec ruby scripts/verify_package.rb
# optional full Rails app smoke:
LITESTACK_INTEGRATION=1 bundle exec rake integration:rails81
```

Exercise: migrate/CRUD on Litedb, cache read/write, enqueue/perform a job, Action Cable message, two clean shutdowns.

## Lifecycle notes

Connections, workers, and `at_exit` hooks are idempotent. Double `close`/`shutdown` must not raise. Prefer explicit shutdown in Puma/job process stop hooks.
