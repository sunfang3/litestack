# frozen_stringe_literal: true

# all components should require the support module
require_relative "litesupport"
require_relative "litemetric"
require_relative "litecache/l1"

##
# Litecache is a caching library for Ruby applications that is built on top of SQLite. It is designed to be simple to use, very fast, and feature-rich, providing developers with a reliable and efficient way to cache data.
#
# One of the main features of Litecache is automatic key expiry, which allows developers to set an expiration time for each cached item. This ensures that cached data is automatically removed from the cache after a certain amount of time has passed, reducing the risk of stale data being served to users.
#
# In addition, Litecache supports LRU (Least Recently Used) removal, which means that if the cache reaches its capacity limit, the least recently used items will be removed first to make room for new items. This ensures that the most frequently accessed data is always available in the cache.
#
# Litecache also supports integer value increment/decrement, which allows developers to increment or decrement the value of a cached item in a thread-safe manner. This is useful for implementing counters or other types of numerical data that need to be updated frequently.
#
# Optional process-local L1 (default off): see docs/plans/litecache-l1-honker-design-review.md
#   Litecache.new(l1: true, l1_max_entries: 10_000, l1_ttl: 0)

class Litecache
  include Litesupport::Liteconnection
  include Litemetric::Measurable

  # the default options for the cache
  # can be overridden by passing new options in a hash
  # to Litecache.new
  #   path: "./cache.db"
  #   expiry: 60 * 60 * 24 * 30 -> one month default expiry if none is provided
  #   size: 128 * 1024 * 1024 -> 128MB
  #   mmap_size: 128 * 1024 * 1024 -> 128MB to be held in memory
  #   min_size: 32 * 1024 -> 32KB
  #   return_full_record: false -> only return the payload
  #   sleep_interval: 1 -> 1 second of sleep between cleanup runs
  #   l1: false -> process-local L1 (opt-in)
  #   l1_max_entries: 10_000
  #   l1_max_value_bytes: 65_536 — skip L1 for larger values
  #   l1_ttl: 0 — soft TTL in seconds (0 = only explicit delete/clear/L2 miss)

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
    l1: false,
    l1_max_entries: 10_000,
    l1_max_value_bytes: 65_536,
    l1_ttl: 0
  }

  # creates a new instance of Litecache
  # can optionally receive an options hash which will be merged
  # with the DEFAULT_OPTIONS (the new hash overrides any matching keys in the default one).
  #
  # Example:
  #   litecache = Litecache.new
  #
  #   litecache.set("a", "somevalue")
  #   litecache.get("a") # =>  "somevalue"
  #
  #   litecache.set("b", "othervalue", 1) # expire aftre 1 second
  #   litecache.get("b") # => "othervalue"
  #   sleep 2
  #   litecache.get("b") # => nil
  #
  #   litecache.clear # nothing remains in the cache
  #   litecache.close # optional, you can safely kill the process

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
      run_stmt(:setter, key, value, expires_in)
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
    transaction do |conn|
      keys_and_values.each_pair do |k, v|
        key = k.to_s
        run_stmt(:setter, key, v, expires_in)
        capture(:set, key)
        l1_set(key, v, expires_in: expires_in)
      rescue SQLite3::FullException
        run_stmt(extra_pruner, 0.2)
        run_sql("vacuum")
        retry
      end
    end
    true
  end

  # add a key, value pair to the cache, but only if the key doesn't exist, with an optional expiry value (number of seconds)
  def set_unless_exists(key, value, expires_in = nil)
    key = key.to_s
    expires_in ||= @expires_in
    changes = 0
    @conn.acquire do |cache|
      cache.transaction(:immediate) do
        cache.stmts[:inserter].execute!(key, value, expires_in)
        changes = cache.changes
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

  # get a value by its key
  # if the key doesn't exist or it is expired then null will be returned
  def get(key)
    key = key.to_s
    hit, value = l1_fetch(key)
    if hit
      capture(:get, key, 1)
      return value
    end
    if (record = run_stmt(:getter, key)[0])
      value = record[1]
      # Approximate remaining TTL for L1 soft expiry (best-effort from L2 expires_in unix)
      l1_set(key, value, expires_in: remaining_ttl_from_record(record))
      capture(:get, key, 1)
      return value
    end
    l1_delete(key) # ensure stale L1 cannot linger if L2 expired
    capture(:get, key, 0)
    nil
  end

  # get multiple values by their keys, a hash with values corresponding to the keys
  # is returned,
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

  # delete a key, value pair from the cache
  def delete(key)
    key = key.to_s
    changes = 0
    @conn.acquire do |cache|
      cache.stmts[:deleter].execute!(key)
      changes = cache.changes
    end
    l1_delete(key)
    changes > 0
  end

  # increment an integer value by amount, optionally add an expiry value (in seconds)
  def increment(key, amount = 1, expires_in = nil)
    key = key.to_s
    expires_in ||= @expires_in
    # Counters stay L2-authoritative; drop L1 to avoid cross-read races.
    l1_delete(key)
    @conn.acquire { |cache| cache.stmts[:incrementer].execute!(key, amount, expires_in)[0][0] }
  end

  # decrement an integer value by amount, optionally add an expiry value (in seconds)
  def decrement(key, amount = 1, expires_in = nil)
    increment(key, -amount, expires_in)
  end

  # delete all entries in the cache up limit (ordered by LRU), if no limit is provided approximately 20% of the entries will be deleted
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
    # L2 prune may drop arbitrary keys — flush L1 to avoid serving orphans.
    l1_clear
  end

  # return the number of key, value pairs in the cache
  def count
    run_stmt(:counter)[0][0]
  end

  # return the actual size of the cache file
  # def size
  #  run_stmt(:sizer)[0][0]
  # end

  # delete all key, value pairs in the cache
  def clear
    run_sql("delete FROM data")
    l1_clear
  end

  # close the connection to the cache file (idempotent via Liteconnection)
  def close(timeout: shutdown_timeout)
    @running = false
    l1_clear
    super
  end

  # return the maximum size of the cache
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

  def l1_stats
    if @l1
      @l1.stats
    else
      {
        enabled: false,
        hits: 0,
        misses: 0,
        hit_rate: 0.0,
        entries: 0,
        invalidate_mode: "none"
      }
    end
  end

  private

  def setup
    super # create connection
    @l1 = build_l1
    @bgthread = track_worker(spawn_worker) # create background pruner thread
  end

  def build_l1
    return nil unless truthy?(@options[:l1])

    L1.new(
      max_entries: @options[:l1_max_entries] || 10_000,
      max_value_bytes: @options[:l1_max_value_bytes] || 65_536,
      ttl: @options[:l1_ttl] || 0
    )
  end

  def truthy?(v)
    v == true || v.to_s == "true" || v.to_s == "1"
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

  # record = [id, value, expires_in_unix] from getter
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
    end
  end
end
