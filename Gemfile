# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in litestack.gemspec
gemspec

# Exact development target: Rails 8.1.3 on Ruby 4.0.5 (see docs/plans).
gem "rails", "8.1.3"
gem "sqlite3", "~> 2.0"

# Honker — optional acceleration for LiteJob wakeup / LiteCable transport /
# claim-ack / L1 invalidate / lifecycle stream (see docs/Integration_with_Honker.md).
# Soft-required at runtime; features fall back when the gem is absent.
# Published to GitHub Packages under sunfang3 (not rubygems.org).
source "https://rubygems.pkg.github.com/sunfang3" do
  gem "honker", "0.4.0"
end
