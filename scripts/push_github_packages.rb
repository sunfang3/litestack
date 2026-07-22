#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Build and push litestack to GitHub Packages (owner: sunfang3).
#
#   export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="sunfang3:PAT"  # write:packages
#   # or GEM_HOST_API_KEY="Bearer PAT"
#   bundle exec ruby scripts/push_github_packages.rb
#   # dry run: PUSH=0 bundle exec ruby scripts/push_github_packages.rb
#
# Install in apps:
#
#   source "https://rubygems.pkg.github.com/sunfang3" do
#     gem "litestack", "1.1.0"
#   end
#   export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="user:PAT"  # read:packages

require "fileutils"
require "open3"
require "tmpdir"
require "rubygems/package"

ROOT = File.expand_path("..", __dir__)
OWNER = "sunfang3"
HOST = "https://rubygems.pkg.github.com/#{OWNER}"
Dir.chdir(ROOT)

require_relative "../lib/litestack/version"
version = Litestack::VERSION
gem_name = "litestack-#{version}.gem"
gem_path = File.join(ROOT, gem_name)

def discover_token
  if (env = ENV["BUNDLE_RUBYGEMS__PKG__GITHUB__COM"].to_s).include?(":")
    return env.split(":", 2).last
  end
  if (bearer = ENV["GEM_HOST_API_KEY"].to_s).start_with?("Bearer ")
    return bearer.sub(/\ABearer\s+/i, "")
  end
  if (raw = ENV["GITHUB_TOKEN"].to_s).length > 8
    return raw
  end

  [
    File.expand_path("~/.bundle/config"),
    File.join(ROOT, ".bundle/config")
  ].each do |cfg|
    next unless File.file?(cfg)
    File.foreach(cfg) do |line|
      next unless line.match?(/RUBYGEMS__PKG__GITHUB__COM/)
      if (m = line.match(/:\s*"([^"]+)"/)) || (m = line.match(/:\s*'([^']+)'/)) ||
          (m = line.match(/:\s*(\S+)/))
        val = m[1].to_s.strip
        return val.split(":", 2).last if val.include?(":")
      end
    end
  end
  nil
end

puts "==> building litestack-#{version}.gem"
system("gem", "build", "litestack.gemspec", exception: true)
abort "missing #{gem_path}" unless File.file?(gem_path)

spec = Gem::Package.new(gem_path).spec
host = spec.metadata["allowed_push_host"]
abort "allowed_push_host must be #{HOST}, got #{host.inspect}" unless host == HOST

puts "==> package OK: #{gem_name} (#{File.size(gem_path)} bytes)"
puts "    allowed_push_host=#{host}"

if ENV["PUSH"] == "0"
  puts "==> PUSH=0 — skip gem push"
  exit 0
end

token = discover_token
abort <<~MSG if token.nil? || token.empty?
  No GitHub Packages credentials found.
  Set one of:
    export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="#{OWNER}:PAT"   # write:packages
    export GEM_HOST_API_KEY="Bearer PAT"
    export GITHUB_TOKEN=PAT
MSG

# gem push for GitHub Packages uses Key = Bearer token (not username:password).
# See https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-rubygems-registry
puts "==> gem push --host #{HOST}"
env = ENV.to_h.merge(
  "GEM_HOST_API_KEY" => "Bearer #{token}"
)
# Avoid leaking parent gem credentials that point at rubygems.org only
cmd = [
  "gem", "push", gem_path,
  "--host", HOST,
  "--key", "github_packages"
]

# Write a temporary credentials file for --key github_packages
cred_dir = File.join(Dir.tmpdir, "litestack-gem-creds-#{Process.pid}")
FileUtils.mkdir_p(cred_dir)
cred_file = File.join(cred_dir, "credentials")
File.write(cred_file, ":github_packages: Bearer #{token}\n")
File.chmod(0o600, cred_file)

begin
  full = env.merge("GEM_HOME" => env["GEM_HOME"], "HOME" => cred_dir)
  # gem looks for ~/.gem/credentials relative to HOME
  gem_dir = File.join(cred_dir, ".gem")
  FileUtils.mkdir_p(gem_dir)
  FileUtils.mv(cred_file, File.join(gem_dir, "credentials"))

  stdout, stderr, status = Open3.capture3(full, *cmd)
  puts stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  abort "gem push failed (#{status.exitstatus})" unless status.success?
ensure
  FileUtils.rm_rf(cred_dir)
end

puts <<~DONE

  ✅ Pushed litestack-#{version} to #{HOST}

  App install:
    source "https://rubygems.pkg.github.com/#{OWNER}" do
      gem "litestack", "#{version}"
    end
    export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="USERNAME:PAT"  # read:packages
    bundle install

  Package page:
    https://github.com/#{OWNER}/litestack/packages
DONE
