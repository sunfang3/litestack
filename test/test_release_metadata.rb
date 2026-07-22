# frozen_string_literal: true

require_relative "helper"
require "rubygems"

class TestReleaseMetadata < Minitest::Test
  def test_version_is_1_1_0
    assert_equal "1.1.0", Litestack::VERSION
  end

  def test_gemspec_ruby_and_no_rails_runtime
    spec = Gem::Specification.load(File.expand_path("../litestack.gemspec", __dir__))
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.0"))
    refute spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.4.0"))
    runtime = spec.runtime_dependencies.map(&:name)
    refute_includes runtime, "rails"
    refute_includes runtime, "railties"
    refute_includes runtime, "activerecord"
  end

  def test_gemspec_push_host_is_github_packages
    spec = Gem::Specification.load(File.expand_path("../litestack.gemspec", __dir__))
    assert_equal "https://rubygems.pkg.github.com/sunfang3", spec.metadata["allowed_push_host"]
  end

  def test_changelog_has_1_1_0_section
    changelog = File.read(File.expand_path("../CHANGELOG.md", __dir__))
    assert_match(/\[1\.1\.0\]/, changelog)
    assert_match(/\[1\.0\.0\]/, changelog)
  end

  def test_readme_mentions_ruby4_rails81
    readme = File.read(File.expand_path("../README.md", __dir__))
    assert_match(/Ruby\s*4/i, readme)
    assert_match(/Rails\s*8\.1/i, readme)
  end

  def test_migration_guide_exists
    path = File.expand_path("../docs/MIGRATING_TO_RUBY4_RAILS81.md", __dir__)
    assert File.file?(path)
    body = File.read(path)
    assert_match(/backup/i, body)
    assert_match(/Solid/i, body)
  end
end
