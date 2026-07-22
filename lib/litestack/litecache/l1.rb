# frozen_string_literal: true

# Process-local L1 cache in front of LiteCache SQLite (L2).
#
# Default off on Litecache. Coherence beyond same-process is feature-flagged
# separately (see docs/plans/litecache-l1-honker-design-review.md).
class Litecache
  class L1
    Entry = Struct.new(:value, :expires_at)

    attr_reader :hits, :misses

    def initialize(max_entries: 10_000, max_value_bytes: 65_536, ttl: 0, invalidate_mode: "none")
      @max_entries = [max_entries.to_i, 1].max
      @max_value_bytes = [max_value_bytes.to_i, 0].max
      @ttl = ttl.to_f
      @ttl = 0 if @ttl.negative?
      @invalidate_mode = invalidate_mode.to_s
      @mutex = Mutex.new
      @map = {}
      @hits = 0
      @misses = 0
    end

    # Returns [true, value] on hit (value may be nil/false), or [false, nil] on miss.
    def fetch(key)
      @mutex.synchronize do
        entry = @map[key]
        unless entry
          @misses += 1
          return [false, nil]
        end
        if expired?(entry)
          @map.delete(key)
          @misses += 1
          return [false, nil]
        end
        # LRU: move to end (Ruby Hash insertion order)
        @map.delete(key)
        @map[key] = entry
        @hits += 1
        [true, entry.value]
      end
    end

    def get(key)
      hit, value = fetch(key)
      hit ? value : nil
    end

    # Returns true if stored, false if skipped (too large).
    def set(key, value, expires_in: nil)
      return false unless acceptable?(value)

      expires_at = compute_expires_at(expires_in)
      @mutex.synchronize do
        @map.delete(key)
        @map[key] = Entry.new(value: value, expires_at: expires_at)
        evict_overflow!
        true
      end
    end

    def delete(key)
      @mutex.synchronize { !!@map.delete(key) }
    end

    def clear
      @mutex.synchronize { @map.clear }
    end

    def size
      @mutex.synchronize { @map.size }
    end

    def hit_rate
      @mutex.synchronize do
        total = @hits + @misses
        return 0.0 if total.zero?

        @hits.to_f / total
      end
    end

    def stats
      @mutex.synchronize do
        total = @hits + @misses
        {
          enabled: true,
          hits: @hits,
          misses: @misses,
          hit_rate: total.zero? ? 0.0 : (@hits.to_f / total),
          entries: @map.size,
          max_entries: @max_entries,
          max_value_bytes: @max_value_bytes,
          ttl: @ttl,
          invalidate_mode: @invalidate_mode
        }
      end
    end

    def reset_stats!
      @mutex.synchronize do
        @hits = 0
        @misses = 0
      end
    end

    private

    def acceptable?(value)
      return true if @max_value_bytes <= 0

      estimate_bytes(value) <= @max_value_bytes
    end

    def estimate_bytes(value)
      case value
      when String then value.bytesize
      when Integer, Float, TrueClass, FalseClass, NilClass then 16
      when Symbol then value.to_s.bytesize
      else
        value.to_s.bytesize
      end
    end

    def compute_expires_at(expires_in)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      candidates = []
      candidates << (now + @ttl) if @ttl.positive?
      if expires_in&.to_f&.positive?
        candidates << (now + expires_in.to_f)
      end
      candidates.min
    end

    def expired?(entry)
      entry.expires_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= entry.expires_at
    end

    def evict_overflow!
      while @map.size > @max_entries
        @map.shift
      end
    end
  end
end
