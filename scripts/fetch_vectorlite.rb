#!/usr/bin/env ruby
# frozen_string_literal: true

# Download vectorlite-py wheel from PyPI and extract vectorlite.[so|dylib|dll]
# into vendor/vectorlite/<platform>/ for Litevector.
#
# Usage:
#   bundle exec ruby scripts/fetch_vectorlite.rb
#   VECTORLITE_VERSION=0.2.0 bundle exec ruby scripts/fetch_vectorlite.rb
#
# Requires network access. Uses only Ruby stdlib (open-uri, rubygems, fileutils, json).

require "fileutils"
require "json"
require "open-uri"
require "rbconfig"
require "rubygems/package"
require "tmpdir"
require "zlib"

VERSION = ENV.fetch("VECTORLITE_VERSION", "0.2.0")
ROOT = File.expand_path("..", __dir__)

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

def wheel_tag_candidates(platform)
  case platform
  when "linux-x86_64"
    %w[
      manylinux_2_17_x86_64.manylinux2014_x86_64
      manylinux2014_x86_64
      manylinux_2_28_x86_64
    ]
  when "linux-arm64"
    %w[
      manylinux_2_17_aarch64.manylinux2014_aarch64
      manylinux2014_aarch64
    ]
  when "darwin-x86_64"
    %w[macosx_10_9_x86_64 macosx_11_0_x86_64]
  when "darwin-arm64"
    %w[macosx_11_0_arm64]
  when "windows-x86_64"
    %w[win_amd64]
  else
    []
  end
end

def fetch_pypi_urls(version)
  uri = "https://pypi.org/pypi/vectorlite-py/#{version}/json"
  JSON.parse(URI.open(uri, "User-Agent" => "litestack-fetch-vectorlite/1.0").read)
rescue OpenURI::HTTPError => e
  raise "failed to fetch PyPI metadata for vectorlite-py #{version}: #{e.message}"
end

def pick_wheel(meta, platform)
  tags = wheel_tag_candidates(platform)
  urls = meta.fetch("urls").select { |u| u["packagetype"] == "bdist_wheel" && u["filename"].end_with?(".whl") }
  tags.each do |tag|
    hit = urls.find { |u| u["filename"].include?(tag) }
    return hit if hit
  end
  # fallback: any wheel whose filename mentions platform hints
  hit = urls.find { |u| u["filename"].include?(platform.split("-").last) }
  hit || raise("no wheel for platform=#{platform} among: #{urls.map { |u| u["filename"] }.join(", ")}")
end

def extract_extension(wheel_path, dest_dir)
  FileUtils.mkdir_p(dest_dir)
  found = nil
  # wheels are zip archives
  require "zip" if defined?(Zip)
  # Prefer stdlib: use `Gem::Package` only for .gem; for zip use unzip via ruby
  begin
    require "zip"
  rescue LoadError
    # pure-ruby zip via shell-out alternative: use Ruby 3+ no zip stdlib — use python or manual
  end

  # Always available path: treat as zip with IO using zlib only for gzip; for zip use:
  extract_with_ruby_zip(wheel_path, dest_dir) { |name| found = name if name }
  found
end

def extract_with_ruby_zip(wheel_path, dest_dir)
  # Minimal ZIP reader for stored/deflated entries (wheels use deflate)
  # Prefer rubyzip if present; else shell to python3 which we used in spike.
  if system("python3", "-c", "import zipfile", out: File::NULL, err: File::NULL)
    py = <<~PY
      import zipfile, sys, os, shutil
      whl, dest = sys.argv[1], sys.argv[2]
      os.makedirs(dest, exist_ok=True)
      found = None
      with zipfile.ZipFile(whl) as z:
          for n in z.namelist():
              base = os.path.basename(n)
              if base.startswith("vectorlite") and base.endswith((".so", ".dylib", ".dll")):
                  out = os.path.join(dest, base)
                  with z.open(n) as src, open(out, "wb") as dst:
                      shutil.copyfileobj(src, dst)
                  found = out
                  print(found)
                  break
      if not found:
          raise SystemExit("vectorlite extension not found in wheel")
    PY
    out = IO.popen(["python3", "-c", py, wheel_path, dest_dir], err: %i[child out], &:read)
    raise "extract failed: #{out}" unless $?.success?
    return out.strip
  end
  raise "python3 required to extract wheel (no rubyzip)"
end

platform = platform_key
dest = File.join(ROOT, "vendor", "vectorlite", platform)
puts "platform=#{platform} version=#{VERSION} dest=#{dest}"

meta = fetch_pypi_urls(VERSION)
wheel = pick_wheel(meta, platform)
url = wheel.fetch("url")
filename = wheel.fetch("filename")
puts "wheel=#{filename}"
puts "url=#{url}"

Dir.mktmpdir("vectorlite-fetch-") do |tmp|
  wheel_path = File.join(tmp, filename)
  URI.open(url, "User-Agent" => "litestack-fetch-vectorlite/1.0") do |io|
    File.binwrite(wheel_path, io.read)
  end
  path = extract_with_ruby_zip(wheel_path, dest)
  puts "installed=#{path}"
  puts "size=#{File.size(path)}"
end

puts "Done. Set LITEVECTOR_EXTENSION_PATH=#{dest}/vectorlite.so (or .dylib/.dll)"
