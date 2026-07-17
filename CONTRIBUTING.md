# Contributing to Litestack

## Supported development stack

- Ruby **4.0.5** (see `.ruby-version`)
- Rails **8.1.3** (default `Gemfile`)
- Bundler 4
- sqlite3 2.x

Lower-bound CI also runs Ruby 4.0.0 + Rails 8.1.0 (`gemfiles/rails81_min.gemfile`).

## Setup

```bash
ruby -v   # expect 4.0.x
bundle install
```

## Tests

```bash
bundle exec rake test          # unit/integration contracts (preloads coverage)
bundle exec rake standard      # Ruby 4 Standard
bundle exec rake verify        # test + standard + package
```

Coverage starts in `test/helper.rb` before project code loads. Aggregate floors live in that helper / `.simplecov`. New compatibility code targets 100% line/branch coverage.

### Durable upgrade fixtures

Immutable DBs live under:

- `test/fixtures/v0_4_3/` — published 0.4.3 format
- `test/fixtures/v0_4_5/` — pre-modernization commit `e598e1b`

Never regenerate fixtures with modernization code in-process for “historical” claims; use the isolated old gem / worktree approach documented in the manifests. Tests must leave committed checksums unchanged.

### Rails app smoke

```bash
LITESTACK_INTEGRATION=1 bundle exec rake integration:rails81
```

Builds the gem, installs into an isolated GEM_HOME, generates a Rails 8.1 app, runs the install generator, and exercises CRUD/cache smoke.

## Package

```bash
bundle exec ruby scripts/verify_package.rb
bundle exec rake release:dry_run   # never pushes
```

## Style

Standard targets Ruby 4.0. Fix style on files you touch; do not mass-rewrite unrelated legacy debt unless the quality gate requires it.
