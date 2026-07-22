# frozen_stringe_literal: true

# all components should require the support module
require "oj"
require_relative "litesupport"
require_relative "litemetric"
require_relative "wakeup"
require_relative "litecache/l1"
require_relative "litecache/invalidator"

##
# Litecache is a caching library for Ruby applications that is built on top of SQLite. It is designed to be simple to use, very fast, and feature-rich, providing developers with a reliable and efficient way to cache data.
#
# Optional process-local L1 (default off):
#   Litecache.new(l1: true, l1_max_entries: 10_000, l1_ttl: 0)
#
# Multi-process coherence (requires l1):
#   invalidate: :none   — same-process only (default)
#   invalidate: :ttl    — soft L1 TTL bound (eventual)
#   invalidate: :honker — Honker notify on the cache file + listener drops peer L1
#
# See docs/plans/litecache-l1-honker-design-review.md

class Litecache
  include Litesupport::Liteconnection
  include Litemetric::Measurable

  DEFAULT_OPTIONS = {
    path: -> { Litesupport.root.join("cache.sqlite3") },
    config_path: "./litecache.yml",
    sync: 0,
    expiry: 60 * 60 * 24 * 30, # one month
    size: 128 * 1024 * 1024, # 128MB
    mmap_size: 128 * 1024 * 1024, # 128MB
    min_size: 8 * 1024 * 1024, # 16MB
    return_full_record: false, # only return the payload
    sleep_interval: 30, # 30 seconds
    metrics: false,
    # L1 (opt-in)
    l1: false,
    l1_max_entries: 10_000,
    l1_max_value_bytes: 65_536,
    l1_ttl: 0,
    l1_ttl_default: 5, # used when invalidate forces a soft TTL
    # Coherence: :none | :ttl | :honker
    invalidate: :none,
    notify_ops: [:set, :delete, :clear],
    notify_channel: "litecache",
    watcher_poll_interval_ms: 5
  }

  def initialize(options = {})
    options[:size] = DEFAULT_OPTIONS[:min_size] if options[:size] && options[:size] < DEFAULT_OPTIONS[:min_size]
    init(options)
    @expires_in = @options[:expiry] || 60 * 60 * 24 * 30
    collect_metrics if @options[:metrics]
  end

  # add a key, value pair to the cache, with an optional expiry value (number of seconds)
  def set(key, value, expires_in = nil)
    key = key.to_s
    expires_in ||= @expires_in
    begin
      if notify_write?(:set)
        transaction do |conn|
          run_stmt(:setter, key, value, expires_in)
          @invalidator.notify_on_connection(conn, op: :set, key: key)
        end
      else
        run_stmt(:setter, key, value, expires_in)
      end
      capture(:set, key)
    rescue SQLite3::FullException
      transaction do
        run_stmt(extra_pruner, 0.2)
        run_sql("vacuum")
      end
      retry
    end
    l1_set(key, value, expires_in: expires_in)
    true
  end

  # set multiple keys and values in one shot set_multi({k1: v1, k2: v2, ... })
  def set_multi(keys_and_values, expires_in = nil)
    expires_in ||= @expires_in
    written = []
    transaction do |conn|
      keys_and_values.each_pair do |k, v|
        key = k.to_s
        run_stmt(:setter, key, v, expires_in)
        capture(:set, key)
        l1_set(key, v, expires_in: expires_in)
        written << key
      rescue SQLite3::FullException
        run_stmt(extra_pruner, 0.2)
        run_sql("vacuum")
        retry
      end
      if written.any? && notify_write?(:set)
        @invalidator.notify_on_connection(conn, op: :mset, keys: written)
      end
    end
    true
  end

  # add a key, value pair to the cache, but only if the key doesn't exist
  def set_unless_exists(key, value, expires_in = nil)
    key = key.to_s
    expires_in ||= @expires_in
    changes = 0
    @conn.acquire do |cache|
      cache.transaction(:immediate) do
        cache.stmts[:inserter].execute!(key, value, expires_in)
        changes = cache.changes
        if changes > 0 && notify_write?(:set) && @honker_extension_loaded
          cache.execute(
            "SELECT notify(?, ?)",
            [
              @options[:notify_channel] || "litecache",
              Oj.dump({"op" => "set", "key" => key, "src" => @invalidator&.instance_id})
            ]
          )
        end
      end
      capture(:set, key)
    rescue SQLite3::FullException
      cache.stmts[:extra_pruner].execute!(0.2)
      cache.execute("vacuum")
      retry
    end
    if changes > 0
      l1_set(key, value, expires_in: expires_in)
    end
    changes > 0
  end

  def get(key)
    key = key.to_s
    hit, value = l1_fetch(key)
    if hit
      capture(:get, key, 1)
      return value
    end
    if (record = run_stmt(:getter, key)[0])
      value = record[1]
      l1_set(key, value, expires_in: remaining_ttl_from_record(record))
      capture(:get, key, 1)
      return value
    end
    l1_delete(key)
    capture(:get, key, 0)
    nil
  end

  def get_multi(*keys)
    results = {}
    missing = []
    original = {}

    keys.each do |orig|
      key = orig.to_s
      original[key] = orig
      hit, value = l1_fetch(key)
      if hit
        results[orig] = value
        capture(:get, key, 1)
      else
        missing << key
      end
    end

    return results if missing.empty?

    transaction(:deferred) do |conn|
      missing.each do |key|
        if (record = run_stmt(:getter, key)[0])
          value = record[1]
          results[original[key]] = value
          l1_set(key, value, expires_in: remaining_ttl_from_record(record))
          capture(:get, key, 1)
        else
          l1_delete(key)
          capture(:get, key, 0)
        end
      end
    end
    results
  end

  def delete(key)
    key = key.to_s
    deleted = false
    if notify_write?(:delete)
      transaction do |conn|
        res = run_stmt(:deleter, key)
        deleted = res && !res.empty?
        @invalidator.notify_on_connection(conn, op: :delete, key: key)
      end
    else
      @conn.acquire do |cache|
        cache.stmts[:deleter].execute!(key)
        deleted = cache.changes > 0
      end
    end
    l1_delete(key)
    deleted
  end

  def increment(key, amount = 1, expires_in = nil)
    key = key.to_s
    expires_in ||= @expires_in
    # Counters stay L2-authoritative; drop L1 and ask peers to drop too.
    l1_delete(key)
    result = nil
    if notify_write?(:delete)
      transaction do |conn|
        result = run_stmt(:incrementer, key, amount, expires_in)[0][0]
        @invalidator.notify_on_connection(conn, op: :delete, key: key)
      end
    else
      result = @conn.acquire { |cache| cache.stmts[:incrementer].execute!(key, amount, expires_in)[0][0] }
    end
    result
  end

  def decrement(key, amount = 1, expires_in = nil)
    increment(key, -amount, expires_in)
  end

  def prune(limit = nil)
    @conn.acquire do |cache|
      if limit&.is_a? Integer
        cache.stmts[:limited_pruner].execute!(limit)
      elsif limit&.is_a? Float
        cache.stmts[:extra_pruner].execute!(limit)
      else
        cache.stmts[:pruner].execute!
      end
    end
    l1_clear
    if notify_write?(:clear)
      transaction do |conn|
        @invalidator.notify_on_connection(conn, op: :clear)
      end
    end
  end

  def count
    run_stmt(:counter)[0][0]
  end

  def clear
    if notify_write?(:clear)
      transaction do |conn|
        run_sql("delete FROM data")
        @invalidator.notify_on_connection(conn, op: :clear)
      end
    else
      run_sql("delete FROM data")
    end
    l1_clear
  end

  def close(timeout: shutdown_timeout)
    @running = false
    wake_workers!
    begin
      @invalidator&.close
    rescue
      nil
    end
    @invalidator = nil
    l1_clear
    super
  end

  def max_size
    run_sql("SELECT s.page_size * c.max_page_count FROM pragma_page_size() as s, pragma_max_page_count() as c")[0][0].to_f / (1024 * 1024)
  end

  def snapshot
    {
      summary: {
        path: path,
        journal_mode: journal_mode,
        synchronous: synchronous,
        size: size,
        max_size: max_size,
        entries: count
      },
      l1: l1_stats
    }
  end

  def l1_enabled?
    !!@l1
  end

  def invalidate_mode
    (@options[:invalidate] || :none).to_sym
  end

  def l1_stats
    if @l1
      stats = @l1.stats
      stats[:honker] = !!@invalidator&.enabled
      stats
    else
      {
        enabled: false,
        hits: 0,
        misses: 0,
        hit_rate: 0.0,
        entries: 0,
        invalidate_mode: invalidate_mode.to_s,
        honker: false
      }
    end
  end

  private

  def setup
    begin
      @invalidator&.close
    rescue
      nil
    end
    @invalidator = nil

    normalize_coherence_options!
    super # create connection
    @l1 = build_l1
    setup_invalidator!
    @bgthread = track_worker(spawn_worker)
  end

  def normalize_coherence_options!
    mode = (@options[:invalidate] || :none).to_s.to_sym
    mode = :none unless %i[none ttl honker].include?(mode)
    @options[:invalidate] = mode

    case mode
    when :ttl
      @options[:l1] = true
      if @options[:l1_ttl].to_f <= 0
        @options[:l1_ttl] = (@options[:l1_ttl_default] || 5).to_f
      end
    when :honker
      @options[:l1] = true
      # Soft TTL backstop if notify is lost
      if @options[:l1_ttl].to_f <= 0
        @options[:l1_ttl] = (@options[:l1_ttl_default] || 5).to_f
      end
    end
  end

  def setup_invalidator!
    return unless invalidate_mode == :honker

    inv = Invalidator.new(self, options: @options)
    if inv.setup!
      @invalidator = inv
    else
      warn "[litecache] invalidate:honker unavailable; falling back to invalidate:ttl"
      @options[:invalidate] = :ttl
      if @options[:l1_ttl].to_f <= 0
        @options[:l1_ttl] = (@options[:l1_ttl_default] || 5).to_f
      end
      # Rebuild L1 with ttl mode label
      @l1 = build_l1
      @invalidator = nil
    end
  end

  def build_l1
    return nil unless truthy?(@options[:l1])

    L1.new(
      max_entries: @options[:l1_max_entries] || 10_000,
      max_value_bytes: @options[:l1_max_value_bytes] || 65_536,
      ttl: @options[:l1_ttl] || 0,
      invalidate_mode: invalidate_mode.to_s
    )
  end

  def truthy?(v)
    v == true || v.to_s == "true" || v.to_s == "1"
  end

  def notify_write?(op)
    @invalidator&.notifies?(op)
  end

  def l1_fetch(key)
    return [false, nil] unless @l1

    @l1.fetch(key)
  end

  def l1_set(key, value, expires_in: nil)
    return unless @l1

    @l1.set(key, value, expires_in: expires_in)
  end

  def l1_delete(key)
    return unless @l1

    @l1.delete(key)
  end

  def l1_clear
    return unless @l1

    @l1.clear
  end

  def remaining_ttl_from_record(record)
    exp = record[2]
    return nil unless exp

    remaining = exp.to_f - Time.now.to_f
    return 0 if remaining <= 0

    remaining
  rescue
    nil
  end

  def spawn_worker
    waiter = track_waiter
    Litescheduler.spawn do
      while @running
        begin
          @conn.acquire do |cache|
            cache.stmts[:pruner].execute!
          rescue SQLite3::BusyException
            retry
          rescue SQLite3::FullException
            cache.stmts[:extra_pruner].execute!(0.2)
          rescue SQLite3::Exception
            # database is closed
          end
        rescue Litestack::ClosedError, ThreadError
          break
        end
        waiter.sleep(@options[:sleep_interval])
      end
    end
  end

  def create_connection
    super("#{__dir__}/sql/litecache.sql.yml") do |conn|
      conn.cache_size = 2000
      conn.journal_size_limit = [(@options[:size] / 2).to_i, @options[:min_size]].min
      conn.max_page_count = (@options[:size] / conn.page_size).to_i
      conn.case_sensitive_like = true
      maybe_load_honker_extension(conn)
    end
  end

  def maybe_load_honker_extension(conn)
    @honker_extension_loaded = false
    return unless invalidate_mode == :honker
    return unless Litestack::Wakeup::Honker.watchable_path?(@options[:path])
    return unless Litestack::Wakeup::Honker.load_honker_gem!

    ::Honker.setup(conn, extension_path: @options[:honker_extension_path])
    @honker_extension_loaded = true
  rescue => e
    @honker_extension_loaded = false
    @logger&.warn { "[litecache] could not load honker extension: #{e.message}" }
  end
end
