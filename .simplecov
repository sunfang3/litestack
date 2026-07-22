# frozen_string_literal: true

# Central coverage configuration. Loaded when SimpleCov is required (see test/helper.rb).
SimpleCov.start do
  enable_coverage :branch
  add_filter "/test/"
  add_filter "/bench/"
  add_filter "/scripts/"
  add_filter "/gemfiles/"
  add_filter "/vendor/"

  # Measured baseline: line ~86% / branch ~58% on full suite (Ruby 4 + Rails 8.1).
  # Floors apply to full suite only (skip on partial/target runs).
  unless ENV["COVERAGE_PARTIAL"] == "1" || ENV["LITESTACK_PARTIAL_TEST"] == "1"
    minimum_coverage line: 80, branch: 50
  end

  add_group "Core", "lib/litestack"
  add_group "Rails", %w[
    lib/active_record
    lib/active_job
    lib/active_support
    lib/action_cable
    lib/generators
  ]
end
