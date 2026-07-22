#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Scaffold a minimal Rails 8.1 app with Litestack + Honker fully enabled.
#
#   bundle exec ruby scripts/create_honker_rails_app.rb [DEST]
#   bundle exec rake examples:honker_rails DEST=tmp/honker_rails
#
# Requires:
#   - BUNDLE_RUBYGEMS__PKG__GITHUB__COM="user:PAT" (read:packages) for honker
#   - Network for rails new / bundle install
#
# Exit 0 on success.

require "fileutils"
require "optparse"
require "open3"
require "rbconfig"
require "pathname"

ROOT = File.expand_path("..", __dir__)
EXAMPLE = File.join(ROOT, "examples/honker_rails")

opts = {
  dest: nil,
  force: false,
  skip_smoke: false,
  rails_version: ENV.fetch("RAILS_VERSION", "8.1.3"),
  skip_bundle: false
}

parser = OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [DEST] [options]"
  o.on("--force", "Replace existing DEST") { opts[:force] = true }
  o.on("--skip-smoke", "Do not run in-app smoke") { opts[:skip_smoke] = true }
  o.on("--skip-bundle", "Skip bundle install (debug)") { opts[:skip_bundle] = true }
  o.on("--rails-version VER", "Rails version for rails new (default #{opts[:rails_version]})") { |v| opts[:rails_version] = v }
  o.on("-h", "--help") { puts o; exit 0 }
end
parser.parse!
opts[:dest] = ARGV[0] || ENV.fetch("DEST", File.join(ROOT, "tmp/honker_rails"))
dest = File.expand_path(opts[:dest])

# Parent litestack `bundle exec` pollutes BUNDLE_* — strip so the child app
# uses its own Gemfile / install path.
STRIP_ENV_KEYS = %w[
  BUNDLE_GEMFILE
  BUNDLE_BIN_PATH
  BUNDLER_VERSION
  BUNDLE_APP_CONFIG
  BUNDLE_PATH
  BUNDLE_WITHOUT
  BUNDLE_WITH
  BUNDLE_DEPLOYMENT
  RUBYOPT
].freeze

def child_env(chdir: nil, extra: {})
  env = ENV.to_h
  STRIP_ENV_KEYS.each { |k| env.delete(k) }
  # Force the child app Gemfile when running inside DEST
  if chdir
    gemfile = File.expand_path(File.join(chdir, "Gemfile"))
    env["BUNDLE_GEMFILE"] = gemfile if File.file?(gemfile)
  end
  extra.each { |k, v| env[k.to_s] = v unless v.nil? }
  # Never inherit a parent Gemfile through empty-string overrides
  env.delete("BUNDLE_GEMFILE") if env["BUNDLE_GEMFILE"].to_s.empty?
  env.compact
end

def sh!(*cmd, chdir: nil, env: {})
  puts "  $ #{cmd.join(" ")}"
  full_env = child_env(chdir: chdir, extra: env)
  popen_opts = {}
  popen_opts[:chdir] = chdir if chdir
  stdout, stderr, status = Open3.capture3(full_env, *cmd, **popen_opts)
  puts stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  raise "command failed (#{status.exitstatus}): #{cmd.join(" ")}" unless status.success?
  stdout
end

def which(bin)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, bin)
    return path if File.executable?(path)
  end
  nil
end

abort "examples/honker_rails missing at #{EXAMPLE}" unless File.directory?(EXAMPLE)

if File.exist?(dest)
  if opts[:force]
    puts "Removing existing #{dest}"
    FileUtils.rm_rf(dest)
  else
    abort "DEST already exists: #{dest}\n  re-run with --force or DEST=other_path"
  end
end

def discover_packages_credentials!
  return if ENV["BUNDLE_RUBYGEMS__PKG__GITHUB__COM"].to_s.include?(":")

  [
    File.expand_path("~/.bundle/config"),
    File.join(ROOT, ".bundle/config")
  ].each do |cfg|
    next unless File.file?(cfg)
    File.foreach(cfg) do |line|
      # YAML: BUNDLE_RUBYGEMS__PKG__GITHUB__COM: "user:token"
      next unless line.match?(/RUBYGEMS__PKG__GITHUB__COM/)
      if (m = line.match(/:\s*"([^"]+)"/)) || (m = line.match(/:\s*'([^']+)'/)) ||
          (m = line.match(/:\s*(\S+)/))
        val = m[1].to_s.strip
        if val.include?(":")
          ENV["BUNDLE_RUBYGEMS__PKG__GITHUB__COM"] = val
          return
        end
      end
    end
  end
end

discover_packages_credentials!

unless ENV["BUNDLE_RUBYGEMS__PKG__GITHUB__COM"].to_s.include?(":")
  warn <<~MSG
    WARNING: BUNDLE_RUBYGEMS__PKG__GITHUB__COM is not set to "user:PAT".
    Honker installs from GitHub Packages (rubygems.pkg.github.com/sunfang3).
    Example: export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="you:ghp_…"
  MSG
end

puts "==> Scaffolding Honker Rails app at #{dest}"
FileUtils.mkdir_p(File.dirname(dest))

# Prefer project bundler env for rails CLI when available.
rails_bin = which("rails")
if rails_bin.nil?
  puts "==> Installing rails #{opts[:rails_version]} into user gem path (no rails CLI found)"
  sh!("gem", "install", "rails", "-v", opts[:rails_version], "--no-document")
  rails_bin = which("rails") || "rails"
end

puts "==> rails new (sqlite3, skip-solid)"
# Avoid --minimal: it skips Active Job and Action Cable, which this demo needs.
sh!(
  rails_bin, "new", dest,
  "--skip-test",
  "--skip-system-test",
  "--skip-bootsnap",
  "--skip-javascript",
  "--skip-hotwire",
  "--skip-asset-pipeline",
  "--skip-solid", # use Litestack instead of Solid Cache/Queue/Cable
  "--skip-kamal",
  "--skip-thruster",
  "-d", "sqlite3",
  "--skip-bundle" # we rewrite Gemfile first
)

# --- Gemfile ---
gemfile = File.join(dest, "Gemfile")
gemfile_body = File.read(gemfile)
unless gemfile_body.include?("litestack")
  File.open(gemfile, "a") do |f|
    f.puts <<~RUBY

      # Litestack from local checkout (example scaffold)
      gem "litestack", path: #{ROOT.inspect}

      # Honker peer (GitHub Packages). require: false so Honker's Railtie does not
      # auto-bootstrap on the primary AR DB (Litestack loads Honker when needed).
      source "https://rubygems.pkg.github.com/sunfang3" do
        gem "honker", "0.4.0", require: false
      end
    RUBY
  end
end

# Persist Packages credentials for the child app (honker source)
if ENV["BUNDLE_RUBYGEMS__PKG__GITHUB__COM"].to_s.include?(":")
  FileUtils.mkdir_p(File.join(dest, ".bundle"))
  File.write(File.join(dest, ".bundle/config"), <<~YAML)
    ---
    BUNDLE_RUBYGEMS__PKG__GITHUB__COM: "#{ENV["BUNDLE_RUBYGEMS__PKG__GITHUB__COM"]}"
  YAML
end

bundle_bin = [RbConfig.ruby, "-S", "bundle"]
pkg_env = {
  "BUNDLE_RUBYGEMS__PKG__GITHUB__COM" => ENV["BUNDLE_RUBYGEMS__PKG__GITHUB__COM"]
}.compact

unless opts[:skip_bundle]
  puts "==> bundle install"
  # Use ruby -S bundle so we do not re-enter the parent litestack bundle exec.
  # Explicit BUNDLE_GEMFILE so path-gem resolution cannot fall back to the
  # litestack repo Gemfile (seen with `bundle lock` writing the wrong file).
  pkg_env = pkg_env.merge("BUNDLE_GEMFILE" => File.join(dest, "Gemfile"))
  sh!(*bundle_bin, "install", chdir: dest, env: pkg_env)
  lock = File.join(dest, "Gemfile.lock")
  warn "NOTE: Gemfile.lock missing in #{dest} after install" unless File.file?(lock)
end

puts "==> rails generate litestack:install"
sh!(*bundle_bin, "exec", "rails", "generate", "litestack:install", "--force", chdir: dest, env: pkg_env)

puts "==> Overlay Honker-on configs from examples/honker_rails"
%w[
  config/litejob.yml
  config/litecache.yml
  config/cable.yml
  config/initializers/honker_ar_setup.rb
].each do |rel|
  src = File.join(EXAMPLE, rel)
  dst = File.join(dest, rel)
  FileUtils.mkdir_p(File.dirname(dst))
  FileUtils.cp(src, dst)
  puts "  wrote #{rel}"
end

FileUtils.mkdir_p(File.join(dest, "app/jobs"))
FileUtils.cp(
  File.join(EXAMPLE, "app/jobs/demo_honker_job.rb"),
  File.join(dest, "app/jobs/demo_honker_job.rb")
)
FileUtils.mkdir_p(File.join(dest, "script"))
FileUtils.cp(
  File.join(EXAMPLE, "script/smoke_honker.rb"),
  File.join(dest, "script/smoke_honker.rb")
)

# Development: enable cache + jobs like production (generator only patches production)
%w[development production].each do |env|
  path = File.join(dest, "config/environments/#{env}.rb")
  next unless File.exist?(path)
  content = File.read(path)

  cache_snippet = <<~RUBY.chomp
    config.cache_store = :litecache, {
        path: Rails.root.join("storage", Rails.env, "cache.sqlite3").to_s,
        config_path: Rails.root.join("config/litecache.yml").to_s
      }
  RUBY
  job_line = "config.active_job.queue_adapter = :litejob"

  unless content.match?(/config\.cache_store\s*=\s*:litecache/)
    if content.match?(/config\.cache_store\s*=/)
      content.sub!(/config\.cache_store\s*=.*/, cache_snippet)
    elsif content.match?(/#\s*config\.cache_store/)
      content.sub!(/#\s*config\.cache_store.*/, cache_snippet)
    else
      content.sub!(/^end\s*\z/, "  #{cache_snippet}\nend")
    end
  end

  unless content.match?(/config\.active_job\.queue_adapter\s*=\s*:litejob/)
    if content.match?(/config\.active_job\.queue_adapter\s*=/)
      content.sub!(/config\.active_job\.queue_adapter\s*=.*/, job_line)
    elsif content.match?(/#\s*config\.active_job\.queue_adapter/)
      content.sub!(/#\s*config\.active_job\.queue_adapter.*/, job_line)
    else
      content.sub!(/^end\s*\z/, "  #{job_line}\nend")
    end
  end

  File.write(path, content)
  puts "  patched config/environments/#{env}.rb"
end

# Ensure storage dirs exist
%w[development test production].each do |env|
  FileUtils.mkdir_p(File.join(dest, "storage", env))
end

# Copy a short app README
File.write(File.join(dest, "HONKER_DEMO.md"), <<~MD)
  # This app was scaffolded by litestack `examples:honker_rails`

  - Config overlays: `config/litejob.yml`, `config/litecache.yml`, `config/cable.yml`
  - Demo job: `app/jobs/demo_honker_job.rb`
  - Smoke: `bin/rails runner script/smoke_honker.rb`

  Upstream docs: see litestack `docs/HONKER.md` and `examples/honker_rails/README.md`.

  ```bash
  bin/rails runner script/smoke_honker.rb
  LITEBOARD_QUEUE_PATH=storage/development/queue.sqlite3 bundle exec liteboard
  ```
MD

unless opts[:skip_bundle]
  puts "==> db:prepare"
  sh!(*bundle_bin, "exec", "rails", "db:prepare", chdir: dest, env: pkg_env)
end

unless opts[:skip_smoke] || opts[:skip_bundle]
  puts "==> smoke (Honker job + cache + status)"
  sh!(*bundle_bin, "exec", "rails", "runner", "script/smoke_honker.rb", chdir: dest, env: pkg_env)
end

puts <<~DONE

  ✅ Honker Rails app ready: #{dest}

  Next:
    cd #{dest}
    bin/rails runner script/smoke_honker.rb
    bin/rails runner 'DemoHonkerJob.perform_later("hi")'
    LITEBOARD_QUEUE_PATH=storage/development/queue.sqlite3 bundle exec liteboard

  Status probe (from litestack repo, against this app's queue file):
    LITESTACK_HONKER_PATH=#{dest}/storage/development/queue.sqlite3 \\
      bundle exec rake litestack:honker:status
DONE
