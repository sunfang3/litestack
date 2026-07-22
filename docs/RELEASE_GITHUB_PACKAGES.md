# Publishing litestack to GitHub Packages

This fork (`sunfang3/litestack`) publishes **only** to GitHub Packages, not
RubyGems.org.

| Item | Value |
|------|--------|
| Host | `https://rubygems.pkg.github.com/sunfang3` |
| Package | `litestack` |
| Current | **1.1.0** |

---

## One-time auth (publisher)

PAT needs **`write:packages`** (and `repo` if the package is linked to a private repo).

```bash
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="sunfang3:YOUR_PAT"
# or
export GEM_HOST_API_KEY="Bearer YOUR_PAT"
```

---

## Release steps

```bash
# 1. Version already set in lib/litestack/version.rb + CHANGELOG
# 2. Verify package
bundle exec rake package:verify

# 3. Push gem
bundle exec rake release:github_packages
# dry-run build only:
PUSH=0 bundle exec ruby scripts/push_github_packages.rb

# 4. Tag (optional but recommended)
git tag -a v1.1.0 -m "litestack 1.1.0 — Honker integration (GitHub Packages)"
git push origin v1.1.0
```

---

## Install in an application

```ruby
# Gemfile
source "https://rubygems.org"

source "https://rubygems.pkg.github.com/sunfang3" do
  gem "litestack", "1.1.0"
  gem "honker", "0.4.0"   # optional peer for Honker features
end
```

```bash
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="YOUR_GH_USERNAME:YOUR_PAT"  # read:packages
bundle install
```

See also: [HONKER.md](HONKER.md), [examples/honker_rails/](../examples/honker_rails/).
