# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in litestack.gemspec
gemspec

# Exact development target: Rails 8.1.3 on Ruby 4.0.5 (see docs/plans).
gem "rails", "8.1.3"
gem "sqlite3", "~> 2.0"

# Optional acceleration layer for LiteJob wakeup / LiteCable transport /
# claim-ack backend (see docs/Integration_with_Honker.md). Path points at the
# local fork used for development; release consumers add `gem "honker"` themselves.
gem "honker", path: "../honker/packages/honker-ruby", require: false
