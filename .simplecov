# frozen_string_literal: true

# Central coverage configuration. Started from test/helper.rb before project requires.
SimpleCov.start do
  enable_coverage :branch
  add_filter "/test/"
  add_filter "/bench/"
  add_filter "/scripts/"
  add_filter "/gemfiles/"
  add_filter "/vendor/"

  # Measured baseline: line ~86% / branch ~58% on full suite (Ruby 4 + Rails 8.1).
  # Keep line floor at 80%; suite must clear it without optional native binaries.
  minimum_coverage line: 80, branch: 50

  add_group "Core", "lib/litestack"
  add_group "Rails", %w[
    lib/active_record
    lib/active_job
    lib/active_support
    lib/action_cable
    lib/generators
  ]
end
