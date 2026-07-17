# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  # Preload helper so SimpleCov starts before any test file loads project code.
  t.ruby_opts << "-r./test/helper"
  t.test_files = FileList["test/**/test_*.rb"].exclude("test/integration/**/*")
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.ruby_opts << "-r./test/helper"
    t.test_files = FileList["test/test_*.rb"]
    t.warning = false
  end
end

namespace :integration do
  desc "Built-gem Rails 8.1 application smoke test"
  task :rails81 do
    ruby "-Itest", "test/integration/rails81_app_test.rb"
  end
end

namespace :scripts do
  desc "Finite smoke of diagnostic scripts (non-blocking polish)"
  task :smoke do
    sh "bundle exec ruby scripts/test_metrics.rb --duration 1 || true"
  end
end

namespace :bench do
  desc "Finite benchmark smoke (non-blocking)"
  task :smoke do
    puts "bench:smoke — run manually from bench/ after deps resolve (see BENCHMARKS.md)"
  end
end

namespace :package do
  desc "Build gem and run package inspection / isolated install smoke"
  task :verify do
    sh "bundle exec ruby scripts/verify_package.rb"
  end
end

namespace :release do
  desc "Release-candidate dry run: build, verify, install — never push"
  task dry_run: ["test", "standard", "package:verify"] do
    require_relative "lib/litestack/version"
    abort "VERSION must be 1.0.0 for this modernization release" unless Litestack::VERSION == "1.0.0"
    puts "release:dry_run OK for litestack-#{Litestack::VERSION} (no push/tag)"
  end
end

desc "Full verification: tests + style + package"
task verify: ["test", "standard", "package:verify"]

require "standard/rake"

task default: %i[test standard]
