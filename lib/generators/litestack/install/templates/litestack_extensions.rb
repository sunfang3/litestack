# frozen_string_literal: true

# Optional SQLite loadable extensions for Litestack.
# Full guide: https://github.com/oldmoe/litestack/blob/master/docs/RAILS_FULL_STACK.md
#
# Install binaries into THIS app (not the gem tree), from the Rails root:
#
#   export LITESTACK_EXTENSION_ROOT="$PWD"
#   bundle exec ruby "$(bundle show litestack)/scripts/fetch_simple.rb"
#   bundle exec ruby "$(bundle show litestack)/scripts/fetch_vectorlite.rb"
#
# Then restart the server. Missing files only log a message — core Litestack
# (Litedb / Litecache / Litejob / Litecable / English FTS) still works.

platform =
  case RUBY_PLATFORM
  when /linux.*aarch64|linux.*arm64/ then "linux-arm64"
  when /linux/ then "linux-x86_64"
  when /darwin.*arm64|darwin.*aarch64/ then "darwin-arm64"
  when /darwin/ then "darwin-x86_64"
  else
    "linux-x86_64"
  end

simple = Rails.root.join("vendor/simple", platform, "libsimple.so")
# macOS may use .dylib
simple = Rails.root.join("vendor/simple", platform, "libsimple.dylib") if !simple.exist? && RUBY_PLATFORM.match?(/darwin/)

vector = Rails.root.join("vendor/vectorlite", platform, "vectorlite.so")
vector = Rails.root.join("vendor/vectorlite", platform, "vectorlite.dylib") if !vector.exist? && RUBY_PLATFORM.match?(/darwin/)

if simple.exist?
  Rails.application.config.litestack.simple_extension_path = simple
else
  Rails.logger&.debug { "[litestack] libsimple not at #{simple} — tokenizer :simple unavailable (optional)" }
end

if vector.exist?
  Rails.application.config.litestack.vector_extension_path = vector
else
  Rails.logger&.debug { "[litestack] vectorlite not at #{vector} — Litevector unavailable (optional)" }
end
