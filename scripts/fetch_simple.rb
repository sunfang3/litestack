#!/usr/bin/env ruby
# frozen_string_literal: true

# Download wangfenjin/simple (libsimple) from GitHub Releases into
# vendor/simple/<platform>/ for Litesearch Chinese + Pinyin support.
#
# Usage:
#   bundle exec ruby scripts/fetch_simple.rb
#   SIMPLE_VERSION=v0.7.1 bundle exec ruby scripts/fetch_simple.rb
#
# Requires: network, python3 (for zip extract), gh optional (uses HTTPS API).

require "fileutils"
require "json"
require "open-uri"
require "rbconfig"
require "tmpdir"

VERSION = ENV.fetch("SIMPLE_VERSION", "v0.7.1")
ROOT = File.expand_path("..", __dir__)
REPO = "wangfenjin/simple"

def platform_key
  os = RbConfig::CONFIG["host_os"]
  cpu = RbConfig::CONFIG["host_cpu"]
  case os
  when /linux/i
    (cpu =~ /arm|aarch64/i) ? "linux-arm64" : "linux-x86_64"
  when /darwin/i
    (cpu =~ /arm|aarch64/i) ? "darwin-arm64" : "darwin-x86_64"
  when /mswin|mingw|cygwin/i
    "windows-x86_64"
  else
    raise "unsupported host OS: #{os}"
  end
end

def asset_name_for(platform)
  case platform
  when "linux-x86_64" then "libsimple-linux-ubuntu-latest.zip"
  when "linux-arm64" then "libsimple-linux-ubuntu-24.04-arm.zip"
  when "darwin-arm64" then "libsimple-osx-arm64.zip"
  when "darwin-x86_64" then "libsimple-osx-x64.zip"
  when "windows-x86_64" then "libsimple-windows-x64.zip"
  else
    raise "no release asset mapping for #{platform}"
  end
end

def fetch_release_json(tag)
  uri = "https://api.github.com/repos/#{REPO}/releases/tags/#{tag}"
  JSON.parse(URI.open(uri, "User-Agent" => "litestack-fetch-simple/1.0").read)
rescue OpenURI::HTTPError => e
  raise "failed to fetch release #{tag}: #{e.message}"
end

def extract_zip(zip_path, dest_dir)
  FileUtils.mkdir_p(dest_dir)
  py = <<~PY
    import zipfile, sys, os, shutil
    zpath, dest = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(zpath) as z:
        z.extractall(dest)
    # Flatten single top-level dir if present
    entries = [e for e in os.listdir(dest) if not e.startswith(".")]
    if len(entries) == 1 and os.path.isdir(os.path.join(dest, entries[0])):
        inner = os.path.join(dest, entries[0])
        for name in os.listdir(inner):
            shutil.move(os.path.join(inner, name), os.path.join(dest, name))
        os.rmdir(inner)
    for root, dirs, files in os.walk(dest):
        for f in files:
            if f.startswith("libsimple") or f.endswith((".so", ".dylib", ".dll")):
                print(os.path.join(root, f))
  PY
  out = IO.popen(["python3", "-c", py, zip_path, dest_dir], err: %i[child out], &:read)
  raise "extract failed: #{out}" unless $?.success?
  out.lines.map(&:strip).reject(&:empty?)
end

platform = platform_key
asset = asset_name_for(platform)
dest = File.join(ROOT, "vendor", "simple", platform)
puts "platform=#{platform} version=#{VERSION} asset=#{asset}"
puts "dest=#{dest}"

meta = fetch_release_json(VERSION)
url_entry = meta.fetch("assets").find { |a| a["name"] == asset }
raise "asset #{asset} not in release #{VERSION}" unless url_entry
url = url_entry.fetch("browser_download_url")
puts "url=#{url}"

Dir.mktmpdir("simple-fetch-") do |tmp|
  zip_path = File.join(tmp, asset)
  URI.open(url, "User-Agent" => "litestack-fetch-simple/1.0") do |io|
    File.binwrite(zip_path, io.read)
  end
  FileUtils.rm_rf(dest)
  files = extract_zip(zip_path, dest)
  puts "installed:"
  files.each { |f| puts "  #{f} (#{File.size(f)} bytes)" }
end

so = Dir[File.join(dest, "libsimple*"), File.join(dest, "*.so"), File.join(dest, "*.dylib")].first
puts "Done. Set LITESEARCH_SIMPLE_EXTENSION_PATH=#{so}" if so
