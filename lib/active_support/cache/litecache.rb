# frozen_string_literal: true

require_relative "../../litestack/compatibility"
Litestack::Compatibility.assert_rails_supported!

require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/cache"

require_relative "../../litestack/litecache"

module ActiveSupport
  module Cache
    class Litecache < Store
      def self.supports_cache_versioning?
        true
      end

      def initialize(options = {})
        super
        @options[:return_full_record] = true
        # Do NOT mutate ActiveSupport::Cache.format_version — use the host app's coder.
        @cache = ::Litecache.new(@options)
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

      def close
        @cache.close
      end

      private

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
