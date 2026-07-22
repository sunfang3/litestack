#!/usr/bin/env ruby
# frozen_string_literal: true

# Build, inspect, and smoke-load the gem from an isolated install path.
require "fileutils"
require "tmpdir"
require "open3"
require "rubygems"
require "rubygems/package"

root = File.expand_path("..", __dir__)
Dir.chdir(root)

require_relative "../lib/litestack/version"

version = Litestack::VERSION
abort "Expected version 1.1.1, got #{version}" unless version == "1.1.1"

puts "== building gem =="
system({"BUNDLE_GEMFILE" => File.join(root, "Gemfile")}, "gem", "build", "litestack.gemspec", exception: true)
gem_path = File.join(root, "litestack-#{version}.gem")
abort "missing built gem #{gem_path}" unless File.file?(gem_path)

puts "== inspecting package =="
pkg = Gem::Package.new(gem_path)
spec = pkg.spec
abort "required_ruby_version must be >= 4.0" unless spec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.0"))
abort "required_ruby_version must reject 3.x" if spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.3.0"))

runtime_deps = spec.runtime_dependencies.map(&:name)
if runtime_deps.include?("rails") || runtime_deps.include?("railties") || runtime_deps.include?("activerecord")
  abort "Rails must not be a runtime dependency (got #{runtime_deps.inspect})"
end

files = pkg.contents
forbidden = files.select { |f| f.start_with?("test/", "bench/", "scripts/", "gemfiles/", "docs/") }
abort "package contains forbidden paths: #{forbidden.inspect}" if forbidden.any?
abort "missing liteboard executable" unless spec.executables.include?("liteboard")

puts "  version=#{spec.version} ruby=#{spec.required_ruby_version} files=#{files.size}"
puts "  runtime_deps=#{runtime_deps.join(", ")}"

puts "== isolated unpack smoke =="
Dir.mktmpdir("litestack-pkg-") do |dir|
  # Unpack gem contents without invoking `gem install` (avoids Bundler GEMFILE issues).
  package_dir = File.join(dir, "package")
  FileUtils.mkdir_p(package_dir)
  Gem::Package.new(gem_path).extract_files(package_dir)

  lib_dir = File.join(package_dir, "lib")
  abort "missing lib in package" unless File.directory?(lib_dir)

  smoke = <<~RUBY
    \$LOAD_PATH.unshift(#{lib_dir.inspect})
    require "sqlite3"
    require "oj"
    require "rack"
    require "logger"
    require "base64"
    require "litestack"
    raise "version mismatch" unless Litestack::VERSION == #{version.inspect}
    %w[Litedb Litecache Litequeue Litecable Litemetric].each { |c| Object.const_get(c) }
    puts "public components loadable: OK"
  RUBY
  out, err, st = Open3.capture3("ruby", "-e", smoke)
  puts out
  warn err unless err.empty?
  abort "install smoke failed" unless st.success?

  # Executable present in package
  exe = File.join(package_dir, "bin", "liteboard")
  abort "liteboard missing from package" unless File.file?(exe)
  puts "liteboard executable packaged: OK"
end

puts "package verification OK"
