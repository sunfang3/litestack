![litestack](https://github.com/oldmoe/litestack/blob/master/assets/litestack_logo_teal_large.png?raw=true)

<a href="https://badge.fury.io/rb/litestack" target="_blank"><img height="21" style='border:0px;height:21px;' border='0' src="https://badge.fury.io/rb/litestack.svg" alt="Gem Version"></a>
<a href='https://rubygems.org/gems/litestack' target='_blank'><img height='21' style='border:0px;height:21px;' src='https://img.shields.io/gem/dt/litestack?color=brightgreen&label=Rubygems%20Downloads' border='0' alt='RubyGems Downloads' /></a>

# Litestack 1.1

**All your data infrastructure, in a gem.**

Litestack is a Ruby gem that gives Ruby and Rails apps an all-in-one SQLite data plane: SQL database, cache, job queue, pub/sub for Action Cable, full-text search, optional vector search, and metrics — without running separate Redis, Postgres, Elasticsearch, or Sidekiq-class services for those roles.

Compared with multi-server stacks, Litestack aims for **high performance**, **low operational surface**, and **simple configuration**. Background workers detect Fiber-based environments (Async/Falcon, Polyphony) and prefer fibers when available.

> **This fork (`sunfang3/litestack`) publishes `1.1.0+` to GitHub Packages only**  
> (`rubygems.pkg.github.com/sunfang3`), not RubyGems.org.  
> Install: **[docs/RELEASE_GITHUB_PACKAGES.md](docs/RELEASE_GITHUB_PACKAGES.md)** ·  
> Upstream history: [oldmoe/litestack](https://github.com/oldmoe/litestack).

Why Litestack: **[WHYLITESTACK.md](WHYLITESTACK.md)** · Benchmarks: **[BENCHMARKS.md](BENCHMARKS.md)**

A typical Rails app using Litestack can drop or avoid:

| Role | Often replaced by |
|------|-------------------|
| Database server | **Litedb** (SQLite) |
| Cache server | **Litecache** |
| Job processor | **Litejob** |
| Pub/sub for Cable | **Litecable** |
| Full-text search | **Litesearch** |
| Vector / ANN search | **Litevector** (optional native) |

![litestack](https://github.com/oldmoe/litestack/blob/master/assets/litestack_advantage.png?raw=true)

---

## Requirements (1.1)

| Runtime | Supported | Unsupported |
|---------|-----------|-------------|
| **Ruby** | `>= 4.0` (verified 4.0.0, 4.0.5+) | Ruby &lt; 4.0 |
| **Rails** (optional) | `>= 8.1, < 9` (verified 8.1.0, 8.1.3) | Rails &lt; 8.1, Rails 9+ |
| **sqlite3** gem | 2.x | 1.x |

- Rails is **not** a runtime dependency. Standalone: `require "litestack"`.
- Loading Railtie/adapters on an unsupported Rails version raises `Litestack::UnsupportedFrameworkVersionError`.
- **Upgrading from 0.4.x:** read **[docs/MIGRATING_TO_RUBY4_RAILS81.md](docs/MIGRATING_TO_RUBY4_RAILS81.md)** (durable backup, quiescence, Solid Cache/Queue cleanup). The install generator **never** auto-deletes Solid gems.
- **1.1.0 highlights:** optional [Honker](docs/HONKER.md) integration (wake / claim-ack / L1 invalidate / cable transport / lifecycle).

---

## Installation (this fork — GitHub Packages)

**Do not** use bare `gem "litestack"` / `bundle add litestack` for **1.1.0+** of this fork — that resolves **RubyGems.org** (upstream), not Packages.

```ruby
# Gemfile
source "https://rubygems.org"

source "https://rubygems.pkg.github.com/sunfang3" do
  gem "litestack", "1.1.0"
  # optional peer for multi-worker wake / L1 / claim / lifecycle:
  gem "honker", "0.4.0"
end
```

```bash
# Classic PAT with at least read:packages (username is your GitHub login)
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="YOUR_GH_USERNAME:YOUR_PAT"
# permanent local config:
#   bundle config set --local rubygems.pkg.github.com "YOUR_GH_USERNAME:YOUR_PAT"

bundle install
```

Rails 8.1+ full stack (after the gem is on the load path):

```bash
bin/rails generate litestack:install
bin/rails db:prepare
```

Package host, visibility, CI secrets: **[docs/RELEASE_GITHUB_PACKAGES.md](docs/RELEASE_GITHUB_PACKAGES.md)**.

The generator wires **Litedb / Litecache / Litejob / Litecable**, drops
`config/initializers/litestack_extensions.rb` (optional paths), and updates
`.gitignore` / `.dockerignore`. Re-runs are largely idempotent.

Native extensions are **optional**. Fetch at install time with explicit flags
(needs network + `python3`), or later manually — see
**[docs/RAILS_FULL_STACK.md](docs/RAILS_FULL_STACK.md)**:

```bash
# one-shot: core stack + both extensions into app vendor/
bin/rails generate litestack:install --with-extensions

# or only one:
bin/rails g litestack:install --with-simple       # Chinese/Pinyin FTS
bin/rails g litestack:install --with-vectorlite   # vector kNN

# manual (Rails root):
export LITESTACK_EXTENSION_ROOT="$PWD"
bundle exec ruby "$(bundle show litestack)/scripts/fetch_simple.rb"
bundle exec ruby "$(bundle show litestack)/scripts/fetch_vectorlite.rb"
```

### Data path

Databases default under `Litesupport.root` (Rails: `./db/<env>/`, else `.`). Prefer late evaluation so dotenv / Rails config apply:

```bash
export LITESTACK_DATA_PATH=/var/lib/myapp
```

```ruby
# config/application.rb or initializer
config.litestack.data_path = Rails.root.join("storage")
# or: Litesupport.data_path = "storage"
```

See issues **#91** / **#34** — path defaults are lazy so late `ENV` and programmatic config are honored.

### Optional Honker (wake / L1 / lifecycle)

[Honker](https://honker.dev) is an **optional** peer gem (not required to install Litestack).  
It accelerates multi-process wake, claim/ack jobs, cache L1 invalidate, and job lifecycle streams.

| | |
|--|--|
| **Install** | Same Packages source as litestack — **[docs/HONKER.md](docs/HONKER.md)** |
| **Gemfile** | Put `gem "honker", "0.4.0"` in the `sunfang3` source block above |
| **Auth** | `BUNDLE_RUBYGEMS__PKG__GITHUB__COM=user:PAT` (`read:packages`) |
| **Defaults** | Polling / no L1 until you opt in |
| **Activate all** | **[docs/HONKER_FULL_STACK_BENCH.md](docs/HONKER_FULL_STACK_BENCH.md)** |
| **Status** | `bundle exec rake litestack:honker:status` |
| **Demo app** | `bundle exec rake examples:honker_rails` |
| **Samples** | `samples/*.honker.yml`, `examples/honker_rails/config/` |

Capability table: **[docs/HONKER.md](docs/HONKER.md)** · full stack: **[docs/RAILS_FULL_STACK.md](docs/RAILS_FULL_STACK.md)**.

---

## Components

| Component | Role | Notes |
|-----------|------|--------|
| **Litedb** | SQLite with concurrency-friendly defaults | Active Record `adapter: litedb`, Sequel `litedb://…` |
| **Litecache** | SQLite-backed cache | Rails `config.cache_store = :litecache` |
| **Litejob** | Durable job queue | Rails `config.active_job.queue_adapter = :litejob`; **zero workers in Rails console** by default |
| **Litecable** | Action Cable adapter | `cable.yml` → `adapter: litecable` |
| **Litesearch** | FTS5 full-text search | AR / Sequel / standalone; optional Chinese + Pinyin |
| **Litevector** | HNSW vector / kNN search | Optional native **vectorlite** extension |
| **Litemetric** / **Liteboard** | Metrics collection + small dashboard | `liteboard` executable |

### Litedb

![litedb](https://github.com/oldmoe/litestack/blob/master/assets/litedb_logo_teal.png?raw=true)

Concurrency-tuned SQLite wrapper (inherits `SQLite3::Database`):

```ruby
require "litestack"
db = Litedb.new(path_to_db)
db.execute("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT)")
db.execute("INSERT INTO users(name) VALUES (?)", "Hamada")
db.query("SELECT count(*) FROM users") # => [[1]]
```

**Active Record** (`config/database.yml`):

```yaml
adapter: litedb
# …usual SQLite path settings
```

**Sequel:**

```ruby
DB = Sequel.connect("litedb://path_to_db_file")
```

### Litecache

![litecache](https://github.com/oldmoe/litestack/blob/master/assets/litecache_logo_teal.png?raw=true)

```ruby
cache = Litecache.new(path: "path_to_file")
cache.set("key", "value")
cache.get("key") #=> "value"
```

Rails:

```ruby
config.cache_store = :litecache, {path: "./path/to/cache.sqlite3"}
```

### Litejob

![litejob](https://github.com/oldmoe/litestack/blob/master/assets/litejob_logo_teal.png?raw=true)

Guide: [Litejob wiki](https://github.com/oldmoe/litestack/wiki/Litejob-guide)

```ruby
class MyJob
  include Litejob
  queue = :default

  def perform(params)
    # …
  end
end

MyJob.perform_async(params)
MyJob.perform_at(time, params)
MyJob.perform_after(delay, params)
```

Rails:

```ruby
config.active_job.queue_adapter = :litejob
```

Optional `litejob.yml` / `config/litejob.yml`:

```yaml
queues:
  - [default, 1]
  - [urgent, 5]
  - [critical, 10, "spawn"]
```

### Litecable

![litecable](https://github.com/oldmoe/litestack/blob/master/assets/litecable_logo_teal.png?raw=true)

`config/cable.yml`:

```yaml
development:
  adapter: litecable
production:
  adapter: litecable
```

### Litesearch

![litesearch](https://github.com/oldmoe/litestack/blob/master/assets/litesearch_logo_teal.png?raw=true)

Full-text search on Litedb (FTS5). Standalone:

```ruby
require "litestack/litedb"
db = Litedb.new(":memory:")
idx = db.search_index("index_name") do |schema|
  schema.fields [:sender, :receiver, :body]
  schema.field :subject, weight: 10
  schema.tokenizer :trigram   # :porter (default), :unicode, :ascii, :trigram, :simple
end
idx.add(sender: "Kamal", receiver: "Laila", subject: "Are the girls awake?", body: "…")
idx.search("kamal")
idx.search("subject: awa")
```

**Active Record:**

```ruby
class Book < ApplicationRecord
  include Litesearch::Model

  litesearch do |schema|
    schema.fields [:title, :description]
    schema.field :author, target: "authors.name"
    schema.tokenizer :porter
  end
end

Book.search("author: writer").limit(10)
```

AR `search` binds the FTS term safely (no SQL string injection of the query).

#### Chinese and Pinyin (`tokenizer :simple`)

Optional [wangfenjin/simple](https://github.com/wangfenjin/simple) FTS5 extension:

```bash
bundle exec ruby scripts/fetch_simple.rb
# or: rake extensions:fetch
export LITESEARCH_SIMPLE_EXTENSION_PATH=vendor/simple/linux-x86_64/libsimple.so
```

```ruby
idx = db.search_index(:articles) do |schema|
  schema.fields [:title, :body]
  schema.tokenizer :simple
  # schema.query_builder :jieba  # needs dict/ next to libsimple
end
idx.add(rowid: 1, title: "国歌", body: "中华人民共和国国歌")
idx.search("中华国歌")   # Chinese
idx.search("zhonghua")   # Pinyin
```

Rails:

```ruby
config.litestack.simple_extension_path = Rails.root.join(
  "vendor/simple/linux-x86_64/libsimple.so"
)
```

Full guide: **[docs/LITESEARCH_ZH_PINYIN.md](docs/LITESEARCH_ZH_PINYIN.md)**

| Tokenizer | Extension | Notes |
|-----------|-----------|--------|
| `:porter` (default) | — | English stemming |
| `:unicode` / `:ascii` / `:trigram` | — | Built-in FTS5 |
| `:simple` | libsimple | Chinese + Pinyin via `simple_query` / `jieba_query` |

### Litevector (optional)

HNSW approximate nearest-neighbor search via [vectorlite](https://github.com/1yefuwang1/vectorlite) (related: issue **#132**).

```bash
bundle exec ruby scripts/fetch_vectorlite.rb
export LITEVECTOR_EXTENSION_PATH=vendor/vectorlite/linux-x86_64/vectorlite.so
```

```ruby
require "litestack/litevector"

index = Litevector::Index.create(
  name: "docs",
  dimensions: 1536,
  distance: :cosine,   # :l2, :cosine, :ip
  max_elements: 100_000
)
index.upsert(1, embedding_float_array)
index.knn(query_array, k: 10, ef: 50)
# => [{id: 1, distance: …}, …]
index.checkpoint!
index.close
```

**Active Record:**

```ruby
class Document < ApplicationRecord
  include Litevector::Model

  litevector do |schema|
    schema.dimensions 1536
    schema.distance :cosine
    schema.max_elements 100_000
    schema.source :embedding
  end
end

doc.reindex_vector!
Document.nearest_neighbors(query, k: 10)
```

Rails:

```ruby
config.litestack.vector_extension_path = Rails.root.join(
  "vendor/vectorlite/linux-x86_64/vectorlite.so"
)
```

Full guide: **[docs/LITEVECTOR.md](docs/LITEVECTOR.md)** · Design notes: `docs/plans/litevector-*.md`

| Constraint | Behavior |
|------------|----------|
| Accuracy | ANN (not exact) |
| Vectors | float32 only |
| IDs | integer ≥ 0 |
| Durability | HNSW file under `Litesupport.root/vector/` (flush on close / `checkpoint!`) |

### Optional native extensions (summary)

```bash
# both vectorlite + libsimple
bundle exec rake extensions:fetch
bundle exec rake extensions:test   # vector + zh/pinyin suites
```

Binaries live under `vendor/` and are **gitignored**; they are not shipped inside the gem package.

### Litemetric and Liteboard

![litemetric](https://github.com/oldmoe/litestack/blob/master/assets/litemetric_logo_teal.png?raw=true)

Enable metrics in the relevant YAML (`metrics: true`). Data is stored under the Litesupport root (e.g. `metric.db`).

```bash
liteboard -h
```

Example dashboards:

![litedb](https://github.com/oldmoe/litestack/blob/master/assets/litedb_metrics.png?raw=true)

![litecache](https://github.com/oldmoe/litestack/blob/master/assets/litecache_metrics.png?raw=true)

---

## Development

```bash
bundle install
bundle exec rake test
bundle exec rake standard
bundle exec ruby scripts/verify_package.rb
```

With optional extensions installed:

```bash
bundle exec rake extensions:fetch
bundle exec rake extensions:test
# or full suite after fetch (helpers resolve vendor/* automatically)
bundle exec rake test
```

Rails app smoke:

```bash
LITESTACK_INTEGRATION=1 bundle exec rake integration:rails81
```

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for worktree / issue-fix workflow and coverage rules.

---

## Documentation

| Doc | Topic |
|-----|--------|
| **[docs/RAILS_FULL_STACK.md](docs/RAILS_FULL_STACK.md)** | **Rails 全栈安装 + libsimple / vectorlite 扩展（必读）** |
| [docs/MIGRATING_TO_RUBY4_RAILS81.md](docs/MIGRATING_TO_RUBY4_RAILS81.md) | 1.0 upgrade, backups, Rails generator, Solid cleanup |
| [docs/LITESEARCH_ZH_PINYIN.md](docs/LITESEARCH_ZH_PINYIN.md) | Chinese / Pinyin FTS (`:simple`) |
| [docs/LITEVECTOR.md](docs/LITEVECTOR.md) | Vector search API and limits |
| [docs/plans/](docs/plans/) | Implementation plans & requirements |
| [WHYLITESTACK.md](WHYLITESTACK.md) | Product rationale |
| [BENCHMARKS.md](BENCHMARKS.md) | Performance notes |
| [FILESYSTEMS.md](FILESYSTEMS.md) | Durable storage / backup filesystem notes |

---

## Contributing

Bug reports and pull requests: [github.com/oldmoe/litestack](https://github.com/oldmoe/litestack).

## License

MIT — see [LICENSE](https://opensource.org/licenses/MIT).
