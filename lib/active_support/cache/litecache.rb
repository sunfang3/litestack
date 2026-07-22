# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/cache"

require_relative "../../litestack/compatibility"
Litestack::Compatibility.assert_rails_supported!

require_relative "../../litestack/litecache"

module ActiveSupport
  module Cache
    # Rails cache store backed by SQLite (::Litecache).
    #
    #   config.cache_store = :litecache
    #   config.cache_store = :litecache, {
    #     path: Rails.root.join("storage", Rails.env, "cache.sqlite3").to_s,
    #     l1: true,
    #     invalidate: :honker, # multi-worker: needs gem "honker"
    #   }
    #
    # L1 / invalidate options are documented in
    # docs/plans/litecache-l1-honker-design-review.md and samples/litecache.honker.yml.
    class Litecache < Store
      # Options forwarded to ::Litecache (everything else stays on the AS Store).
      LITECACHE_OPTION_KEYS = %i[
        path config_path sync expiry size mmap_size min_size
        return_full_record sleep_interval metrics logger
        l1 l1_max_entries l1_max_value_bytes l1_ttl l1_ttl_default
        invalidate notify_ops notify_channel watcher_poll_interval_ms
        honker_extension_path shutdown_timeout
      ].freeze

      def self.supports_cache_versioning?
        true
      end

      def initialize(options = {})
        options = options ? options.dup : {}
        super
        @options[:return_full_record] = true
        # Do NOT mutate ActiveSupport::Cache.format_version — use the host app's coder.
        @cache = ::Litecache.new(litecache_options)
      end

      def increment(key, amount = 1, options = nil)
        key = key.to_s
        options = merged_options(options)
        @cache.transaction do
          if (value = read(key, options))
            amount += value.to_i
          end
          write(key, amount, options)
        end
        amount
      end

      def decrement(key, amount = 1, options = nil)
        options = merged_options(options)
        increment(key, -1 * amount, options)
      end

      def prune(limit = nil, time = nil)
        @cache.prune(limit)
      end

      # Match ActiveSupport::Cache::Store public signature: cleanup(options = nil)
      def cleanup(options = nil)
        limit = options.is_a?(Hash) ? options[:limit] : options
        @cache.prune(limit)
      end

      def clear(options = nil)
        @cache.clear
      end

      def count
        @cache.count
      end

      def size
        @cache.size
      end

      def max_size
        @cache.max_size
      end

      def stats
        @cache.stats
      end

      def l1_stats
        @cache.l1_stats
      end

      def l1_enabled?
        @cache.l1_enabled?
      end

      def invalidate_mode
        @cache.invalidate_mode
      end

      def close
        @cache.close
      end

      private

      def litecache_options
        opts = {}
        LITECACHE_OPTION_KEYS.each do |key|
          opts[key] = @options[key] if @options.key?(key)
          sk = key.to_s
          opts[key] = @options[sk] if @options.key?(sk) && !opts.key?(key)
        end
        opts[:return_full_record] = true
        # Prefer app config/litecache.yml when present and not overridden
        if !opts.key?(:config_path) && defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          yml = Rails.root.join("config/litecache.yml")
          opts[:config_path] = yml.to_s if yml.exist?
        end
        opts
      end

      # Read an entry from the cache.
      def read_entry(key, **options)
        deserialize_entry(@cache.get(key))
      rescue TypeError, ArgumentError
        # Corrupt payload treated as miss
        nil
      end

      def read_multi_entries(names, **options)
        results = {}
        return results if names == [] || names.nil?
        rs = @cache.get_multi(*names.flatten)
        rs.each_pair do |k, v|
          entry = deserialize_entry(v)
          results[k] = entry.value if entry
        rescue TypeError, ArgumentError
          # skip corrupt
        end
        results
      end

      # Write an entry to the cache.
      def write_entry(key, entry, **options)
        write_serialized_entry(key, serialize_entry(entry, **options), **options)
      end

      def write_multi_entries(entries, **options)
        return if entries.nil? || entries.empty?
        # Do not mutate caller input
        serialized = {}
        entries.each_pair { |k, v| serialized[k] = serialize_entry(v, **options) }
        expires_in = options[:expires_in].to_i if options[:expires_in]
        if options[:race_condition_ttl] && expires_in.to_i > 0 && !options[:raw]
          expires_in += 5.minutes
        end
        @cache.set_multi(serialized, expires_in)
      end

      def write_serialized_entry(key, payload, **options)
        expires_in = options[:expires_in].to_i if options[:expires_in]
        if options[:race_condition_ttl] && expires_in.to_i > 0 && !options[:raw]
          expires_in += 5.minutes
        end
        if options[:unless_exist]
          @cache.set_unless_exists(key, payload, expires_in)
        else
          @cache.set(key, payload, expires_in)
        end
      end

      # Delete an entry from the cache.
      def delete_entry(key, **options)
        @cache.delete(key)
      end
    end
  end
end
