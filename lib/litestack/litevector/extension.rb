# frozen_string_literal: true

require "rbconfig"

module Litevector
  # Resolve and load the vectorlite native SQLite extension into a connection.
  module Extension
    module_function

    VENDOR_ROOT = File.expand_path("../../../vendor/vectorlite", __dir__)

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
        "unknown-#{os}-#{cpu}"
      end
    end

    def extension_basenames
      %w[vectorlite.so vectorlite.dylib vectorlite.dll vectorlite]
    end

    def vendored_candidates
      dir = File.join(VENDOR_ROOT, platform_key)
      extension_basenames.map { |b| File.join(dir, b) }
    end

    # Ordered list of paths to try (may not exist).
    def candidate_paths
      explicit = [
        Litevector.extension_path,
        ENV["LITEVECTOR_EXTENSION_PATH"]
      ].compact.map(&:to_s).reject(&:empty?)
      explicit + vendored_candidates
    end

    def resolve_path
      candidates = candidate_paths
      found = candidates.find { |p| File.file?(p) }
      return found if found

      raise ExtensionNotFoundError,
        "vectorlite binary not found. Tried: #{candidates.inspect}. " \
        "Run `bundle exec ruby scripts/fetch_vectorlite.rb` or set LITEVECTOR_EXTENSION_PATH."
    end

    # Load extension into +db+ (SQLite3::Database). Idempotent per connection via ivar flag.
    def load!(db)
      return db if db.instance_variable_get(:@litevector_loaded)

      path = resolve_path
      begin
        db.enable_load_extension(true)
        db.load_extension(path)
      rescue ExtensionNotFoundError
        raise
      rescue => e
        raise ExtensionLoadError, "failed to load vectorlite at #{path}: #{e.class}: #{e.message}"
      ensure
        begin
          db.enable_load_extension(false)
        rescue
          nil
        end
      end

      db.instance_variable_set(:@litevector_loaded, true)
      db.instance_variable_set(:@litevector_extension_path, path)
      path
    end

    def loaded?(db)
      !!db.instance_variable_get(:@litevector_loaded)
    end

    def available?
      candidate_paths.any? { |p| File.file?(p) }
    rescue
      false
    end

    def info(db)
      load!(db)
      db.get_first_value("SELECT vectorlite_info()")
    end
  end
end
