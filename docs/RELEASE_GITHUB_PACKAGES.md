# Publishing & installing litestack (GitHub Packages)

This fork (`sunfang3/litestack`) publishes **only** to **GitHub Packages**, not
RubyGems.org.

| Item | Value |
|------|--------|
| Host | `https://rubygems.pkg.github.com/sunfang3` |
| Package name | `litestack` |
| Current version | **1.1.1** |
| Package page | https://github.com/users/sunfang3/packages/rubygems/package/litestack |
| Repo | https://github.com/sunfang3/litestack |
| Tag | `v1.1.1` |

Related: [HONKER.md](HONKER.md) (optional peer) · [HONKER_FULL_STACK_BENCH.md](HONKER_FULL_STACK_BENCH.md).

---

## 1. Install in an application (consumers)

### Gemfile

```ruby
source "https://rubygems.org"

source "https://rubygems.pkg.github.com/sunfang3" do
  gem "litestack", "1.1.1"
  gem "honker", "0.4.0"   # optional — multi-worker wake / L1 / claim / lifecycle
end
```

### Authenticate Bundler (`read:packages`)

Create a **classic** GitHub PAT with at least:

| Scope | When |
|-------|------|
| **`read:packages`** | Always (download gems) |
| `repo` | Only if the package is **private** and linked to a private repo (often needed) |

```bash
# username = your GitHub login; password = PAT
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="YOUR_GH_USERNAME:YOUR_PAT"

# permanent (local project):
bundle config set --local rubygems.pkg.github.com "YOUR_GH_USERNAME:YOUR_PAT"

bundle install
```

**Do not** use bare:

```ruby
gem "litestack"   # → rubygems.org upstream, not this fork’s 1.1.0
```

### Verify

```bash
bundle exec ruby -e 'require "litestack"; puts Litestack::VERSION'
# => 1.1.0

# Optional Honker live probe (file path required):
bundle exec rake litestack:honker:status
```

---

## 2. Package visibility & permissions

### Current package

As published, the `litestack` package under `sunfang3` is typically **private**
until you change visibility in the GitHub UI.

| Goal | Action |
|------|--------|
| **Only you / CI with secret** | Leave **private**; every client needs PAT + `read:packages` |
| **Public download** | Package page → **Package settings** → **Change visibility** → Public |
| **Org / collaborators** | Grant package **read** to users/teams (or inherit from repo link) |

UI path:

1. Open https://github.com/users/sunfang3/packages/rubygems/package/litestack  
2. **Package settings** (right sidebar)  
3. **Manage Actions access** / **Change package visibility** as needed  
4. Optionally **Connect repository** → `sunfang3/litestack` so repo permissions apply  

### Who needs which PAT scopes

| Role | Scopes | Env / config |
|------|--------|----------------|
| App developer (install) | `read:packages` (+ `repo` if private package) | `BUNDLE_RUBYGEMS__PKG__GITHUB__COM=user:PAT` |
| Release publisher | `write:packages` (+ `repo` if private) | same, or `GEM_HOST_API_KEY=Bearer PAT` |
| GitHub Actions CI | repo secret (see below) | workflow `env` |

### Fine-grained PATs

If you use a fine-grained token, grant:

- **Packages**: Read (consumers) or Read/Write (publish)
- **Repository access**: the linked repo if the package is private

Classic PATs remain the most reliable for Bundler’s `user:token` form.

### Common install errors

| Symptom | Fix |
|---------|-----|
| `Authentication is required for rubygems.pkg.github.com` | Set `BUNDLE_RUBYGEMS__PKG__GITHUB__COM` or `bundle config` |
| `Bad username or password` | Wrong PAT; missing `read:packages`; expired token |
| `Could not find gem 'litestack (= 1.1.1)'` | Auth OK but no package read access, or wrong owner source |
| Resolves old 0.x / wrong gem | Gemfile is still pulling from rubygems.org — use the `source` block above |

---

## 3. CI (GitHub Actions)

This repo’s workflow (`.github/workflows/ruby.yml`):

```yaml
permissions:
  contents: read
  packages: read

env:
  BUNDLE_RUBYGEMS__PKG__GITHUB__COM: ${{ secrets.BUNDLE_RUBYGEMS__PKG__GITHUB__COM || format('{0}:{1}', github.actor, secrets.GITHUB_TOKEN) }}
```

### Recommended secret (no rotation required for this doc)

| Secret name | Value format | Notes |
|-------------|--------------|--------|
| **`BUNDLE_RUBYGEMS__PKG__GITHUB__COM`** | `username:PAT` | PAT needs `read:packages` (and package access if private) |

Set once under **repo → Settings → Secrets and variables → Actions**.

Fallback: `GITHUB_TOKEN` + `packages: read` works for packages owned by the same
user/org when permissions allow; a dedicated secret is more reliable for forks
and private packages.

### Local check that CI will use the same source

```bash
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="user:PAT"
bundle exec rake package:verify
bundle exec rake test:honker
bundle exec rake soak:honker
```

---

## 4. Publishing a new version (maintainers)

PAT needs **`write:packages`**.

```bash
# 1. Bump lib/litestack/version.rb + CHANGELOG
# 2. Verify
bundle exec rake package:verify

# 3. Push gem to Packages
bundle exec rake release:github_packages
# dry-run (build only):
PUSH=0 bundle exec ruby scripts/push_github_packages.rb

# 4. Tag
git tag -a vX.Y.Z -m "litestack X.Y.Z"
git push origin master --tags
```

`allowed_push_host` in the gemspec is locked to:

`https://rubygems.pkg.github.com/sunfang3`

---

## 5. Recent release notes

### 1.1.1 (tag `v1.1.1`)

- Recurring/cron schedules (issue #101)
- CI: Ruby 4.0.5/4.0.6 + Rails 8.1.3 only
- Honker enqueue notify + interruptible sweep (job wake latency)
- Full-stack bench + install/permissions docs

### 1.1.0 (tag `v1.1.0`)

- Optional **Honker** integration (wake / claim / L1 / cable / lifecycle / outbox)
- `rake litestack:honker:status`, soak, examples app

Full list: [CHANGELOG.md](../CHANGELOG.md).
