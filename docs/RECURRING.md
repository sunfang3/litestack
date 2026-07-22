# Recurring tasks (Litejob)

Solid Queue–inspired **cron / interval** schedules that enqueue jobs into the
existing Litejob queue. Resolves [issue #101](https://github.com/oldmoe/litestack/issues/101).

---

## Quick start

### 1. Config file `config/recurring.yml`

```yaml
production:
  cleanup:
    class: CleanupJob
    schedule: every day at 3:00
    queue: default

  poll_api:
    class: PollApiJob
    every: 300          # seconds
    args: []

  hourly:
    class: HourlyJob
    schedule: "0 * * * *"   # standard 5-field cron
```

Sample: `samples/recurring.yml`.

### 2. Ensure workers are running

Recurring ticks only start when `workers > 0` (same process that runs jobs).

```yaml
# config/litejob.yml
production:
  workers: 5
  # optional overrides:
  # recurring_path: "./config/recurring.yml"
  # recurring_tick: 5
```

Or pass a Hash:

```ruby
Litejobqueue.jobqueue(
  path: "storage/queue.sqlite3",
  workers: 2,
  recurring: {
    "ping" => {"class" => "PingJob", "every" => 60}
  }
)
```

### 3. Job class

**Litejob:**

```ruby
class CleanupJob
  include Litejob
  def perform
    # ...
  end
end
```

**ActiveJob:**

```ruby
class CleanupJob < ApplicationJob
  def perform
    # ...
  end
end
```

---

## Schedule formats

| Form | Example |
|------|---------|
| Cron (5 fields) | `"*/5 * * * *"`, `"0 3 * * *"` |
| Interval seconds | `every: 300` |
| English (subset) | `every 5 minutes`, `every hour`, `every day at 3:00`, `every minute` |

No `fugit` / ActiveSupport dependency — cron parsing is built-in.

---

## Exactly-once per slot

- Cron: at most one enqueue per **minute slot** (key `YYYY-MM-DDTHH:MM`).
- Interval: at most one enqueue per **bucket** (`every:N:unix_bucket`).
- State table: `litestack_recurring` on the queue SQLite file.
- Multi-process: Honker **leadership** lock `litestack:litejob:recurring` when available.

---

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `recurring` | `nil` | Inline Hash of schedules |
| `recurring_path` | `./config/recurring.yml` | YAML path (env section used) |
| `recurring_tick` | `5` | Seconds between checks |
| `leadership` | `true` | Single scheduler when Honker works |

You can also embed under `recurring:` in `litejob.yml` for the current env
(if `recurring_path` points at that file).

---

## Rails generator

After `rails g litestack:install`, copy:

```bash
cp "$(bundle show litestack)/samples/recurring.yml" config/recurring.yml
```

Or the install generator installs a commented template when present.

---

## Ops notes

- **Rails console** defaults `workers: 0` → recurring **does not** run there (by design).
- Failed job enqueue rolls back the slot so the next tick retries.
- `command:` eval is supported for Solid Queue parity — prefer `class:` in production.
