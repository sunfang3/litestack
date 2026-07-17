# frozen_string_literal: true

require_relative "lib/litestack/version"

Gem::Specification.new do |spec|
  spec.name = "litestack"
  spec.version = Litestack::VERSION
  spec.authors = ["Mohamed Hassan"]
  spec.email = ["oldmoe@gmail.com"]

  spec.summary = "A SQLite based, lightning fast, super efficient and dead simple to setup and use database, cache and job queue for Ruby and Rails applications!"
  spec.homepage = "https://github.com/oldmoe/litestack"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "https://github.com/oldmoe/litestack/blob/master/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Runtime, license/readme/changelog, and intentional executables only.
  # Prefer filesystem inventory so newly added modernization files package correctly
  # even before the first commit.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["lib/**/*", "bin/*", "LICENSE*", "README*", "CHANGELOG*", "sig/**/*"].select { |f| File.file?(f) }
  end
  spec.bindir = "bin"
  spec.executables = ["liteboard"]
  spec.require_paths = ["lib", "lib/litestack"]

  # Runtime dependencies — Rails is intentionally optional.
  spec.add_dependency "sqlite3", [">= 2.0", "< 3.0"]
  spec.add_dependency "oj", "~> 3"
  spec.add_dependency "rack", "~> 3"
  spec.add_dependency "rackup", "~> 2"
  spec.add_dependency "tilt", "~> 2"
  spec.add_dependency "erubi", "~> 1"
  spec.add_dependency "logger", ">= 1.4"
  spec.add_dependency "base64", ">= 0.2"
  spec.add_dependency "bigdecimal", ">= 3.1"

  # Development dependencies — Rails version is controlled by Gemfile / appraisal gemfiles.
  spec.add_development_dependency "rake", "~> 13"
  spec.add_development_dependency "minitest", "~> 5"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "standard", "~> 1"
  spec.add_development_dependency "sequel", "~> 5"
  spec.add_development_dependency "debug", "~> 1"
end
