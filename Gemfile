# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in litestack.gemspec
gemspec

# Exact development target: Rails 8.1.3 on Ruby 4.0.5 (see docs/plans).
gem "rails", "8.1.3"
gem "sqlite3", "~> 2.0"

# Honker — optional acceleration for LiteJob wakeup / LiteCable transport /
# claim-ack / L1 invalidate / lifecycle stream (see docs/Integration_with_Honker.md).
# Soft-required at runtime (features fall back when missing). For this monorepo
# workspace, pin the local fork; CI/other machines can switch to the github source.
#
# Local (sibling checkout under investigations/):
gem "honker",
  path: "../honker/packages/honker-ruby",
  require: false

# Remote (fork / upstream monorepo — uncomment if path is unavailable):
# gem "honker",
#   github: "sunfang3/honker",
#   glob: "packages/honker-ruby/honker.gemspec",
#   require: false
# # or upstream:
# gem "honker",
#   github: "russellromney/honker",
#   glob: "packages/honker-ruby/honker.gemspec",
#   require: false
