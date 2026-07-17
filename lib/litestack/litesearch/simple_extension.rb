# frozen_string_literal: true

require "rbconfig"

module Litesearch
  # Loads [wangfenjin/simple](https://github.com/wangfenjin/simple) FTS5 tokenizer
  # (Chinese + Pinyin) into a SQLite connection.
  module SimpleExtension
    module_function

    VENDOR_ROOT = File.expand_path("../../../vendor/simple", __dir__)

    class Error < StandardError; end
    class NotFoundError < Error; end
    class LoadError < Error; end

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

    def basenames
      %w[libsimple.so libsimple.dylib simple.dll libsimple.dll simple]
    end

    def vendored_candidates
      dir = File.join(VENDOR_ROOT, platform_key)
      basenames.map { |b| File.join(dir, b) }
    end

    def candidate_paths
      explicit = [
        Litesearch.simple_extension_path,
        ENV["LITESEARCH_SIMPLE_EXTENSION_PATH"],
        ENV["SIMPLE_EXTENSION_PATH"]
      ].compact.map(&:to_s).reject(&:empty?)
      explicit + vendored_candidates
    end

    def resolve_path
      found = candidate_paths.find { |p| File.file?(p) }
      return found if found

      raise NotFoundError,
        "libsimple (wangfenjin/simple) not found. Tried: #{candidate_paths.inspect}. " \
        "Run `bundle exec ruby scripts/fetch_simple.rb` or set LITESEARCH_SIMPLE_EXTENSION_PATH."
    end

    def available?
      candidate_paths.any? { |p| File.file?(p) }
    rescue
      false
    end

    def load!(db)
      return db if db.instance_variable_get(:@litesearch_simple_loaded)

      path = resolve_path
      begin
        db.enable_load_extension(true)
        db.load_extension(path)
      rescue NotFoundError
        raise
      rescue => e
        raise LoadError, "failed to load libsimple at #{path}: #{e.class}: #{e.message}"
      ensure
        begin
          db.enable_load_extension(false)
        rescue
          nil
        end
      end

      db.instance_variable_set(:@litesearch_simple_loaded, true)
      db.instance_variable_set(:@litesearch_simple_path, path)

      # Optional jieba dict directory next to the .so (release zip layout).
      dict = dict_path_for(path)
      if dict && File.directory?(dict)
        begin
          db.execute("SELECT jieba_dict(?)", [dict])
        rescue SQLite3::Exception
          # Builds without jieba still support simple_query / tokenize=simple.
        end
      end

      path
    end

    def loaded?(db)
      !!db.instance_variable_get(:@litesearch_simple_loaded)
    end

    def dict_path_for(extension_path)
      sibling = File.join(File.dirname(extension_path), "dict")
      return sibling if File.directory?(sibling)
      nil
    end
  end

  class << self
    # Filesystem path to libsimple.so / .dylib / .dll
    attr_accessor :simple_extension_path

    def simple_available?
      SimpleExtension.available?
    end

    def reset_simple_configuration!
      @simple_extension_path = nil
    end
  end
end
