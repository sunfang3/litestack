# frozen_string_literal: true

# all components should require the support module
require_relative "litesupport"
require_relative "litemetric"
require_relative "wakeup"

require "base64"
require "oj"
require "securerandom"

class Litecable
  include Litesupport::Liteconnection
  include Litemetric::Measurable

  DEFAULT_OPTIONS = {
    config_path: "./litecable.yml",
    path: -> { Litesupport.root.join("cable.sqlite3") },
    sync: 0,
    mmap_size: 16 * 1024 * 1024, # 16MB
    expire_after: 5, # remove messages older than 5 seconds
    listen_interval: 0.05, # check new messages every 50 milliseconds (polling transport)
    metrics: false,
    # :polling — messages table + interval fetch (default)
    # :honker — notify/listen via honker (optional gem, file-backed path)
    transport: :polling,
    watcher_poll_interval_ms: 5,
    honker_channel_prefix: "litecable:"
  }

  def initialize(options = {})
    @messages = Litesupport::Pool.new(1) { [] }
    init(options)
    collect_metrics if @options[:metrics]
  end

  # broadcast a message to a specific channel
  def broadcast(channel, payload = nil)
    # group meesages and only do broadcast every 10 ms
    # but broadcast locally normally
    if honker_transport?
      honker_broadcast(channel, payload)
    else
      @messages.acquire { |msgs| msgs << [channel.to_s, Oj.dump(payload)] }
    end
    capture(:broadcast, channel)
    local_broadcast(channel, payload)
  end

  # subscribe to a channel, optionally providing a success callback proc
  def subscribe(channel, subscriber, success_callback = nil)
    @subscribers.acquire do |subs|
      subs[channel] = {} unless subs[channel]
      subs[channel][subscriber] = true
    end
    success_callback&.call
    capture(:subscribe, channel)
  end

  # unsubscribe from a channel
  def unsubscribe(channel, subscriber)
    @subscribers.acquire { |subs|
      begin
        subs[channel].delete(subscriber)
      rescue
        nil
      end
    }
    capture(:unsubscribe, channel)
  end

  def close(timeout: shutdown_timeout)
    @running = false
    # Unblock honker wait_for_update so workers can exit promptly.
    begin
      @honker_db&.mark_updated
    rescue
      nil
    end
    super
  end

  private

  def honker_transport?
    t = @options[:transport]
    t = t[:adapter] if t.is_a?(Hash)
    t.to_s == "honker"
  end

  # broadcast the message to local subscribers
  def local_broadcast(channel, payload = nil)
    subscribers = []
    @subscribers.acquire do |subs|
      break unless subs[channel]
      subscribers = subs[channel].keys
    end
    subscribers.each do |subscriber|
      subscriber.call(payload)
      capture(:message, channel)
    end
  end

  def setup
    begin
      @honker_db&.close
    rescue
      nil
    end
    @honker_db = nil

    super # create connection
    @pid = Process.pid
    # Unique per instance so same-process dual adapters still cross-deliver;
    # used to suppress re-delivery of our own notifies (local_broadcast already ran).
    @instance_id = SecureRandom.hex(8)
    @subscribers = Litesupport::Pool.new(1) { {} }
    @running = true
    @last_fetched_id = nil

    if honker_transport? && can_use_honker?
      setup_honker_transport!
    else
      if honker_transport?
        warn "[litestack] litecable transport:honker unavailable; falling back to polling"
        @options[:transport] = :polling
      end
      @listener = track_worker(create_listener)
      @pruner = track_worker(create_pruner)
      @broadcaster = track_worker(create_broadcaster)
    end
  end

  def can_use_honker?
    Litestack::Wakeup::Honker.available?(path: @options[:path])
  end

  def setup_honker_transport!
    raise LoadError, "honker gem not available" unless Litestack::Wakeup::Honker.load_honker_gem!

    opts = {watcher_poll_interval_ms: (@options[:watcher_poll_interval_ms] || 5).to_i}
    opts[:extension_path] = @options[:honker_extension_path] if @options[:honker_extension_path]
    @honker_db = ::Honker::Database.new(@options[:path].to_s, **opts)
    @last_notification_id = @honker_db.db.get_first_value(
      "SELECT COALESCE(MAX(id), 0) FROM _honker_notifications"
    ).to_i
    @listener = track_worker(create_honker_listener)
    @pruner = track_worker(create_honker_pruner)
  end

  def honker_broadcast(channel, payload)
    return unless @honker_db

    prefix = @options[:honker_channel_prefix] || "litecable:"
    notify_channel = "#{prefix}#{channel}"
    # Envelope identifies this Litecable instance so listeners skip their own
    # notifies (local_broadcast already delivered). Pid alone is wrong when two
    # adapters share a process (tests / multi-cable setups).
    envelope = {"_litecable_src" => @instance_id, "data" => payload}
    @honker_db.db.execute(
      "SELECT notify(?, ?)",
      [notify_channel, Oj.dump(envelope)]
    )
    @honker_db.mark_updated
  rescue => e
    @logger&.warn { "[litecable] honker notify failed: #{e.class}: #{e.message}" }
  end

  def create_broadcaster
    waiter = track_waiter
    Litescheduler.spawn do
      while @running
        begin
          @messages.acquire do |msgs|
            if msgs.length > 0
              run_sql("BEGIN IMMEDIATE")
              while (msg = msgs.shift)
                run_stmt(:publish, msg[0], msg[1], @pid)
              end
              run_sql("END")
            end
          end
        rescue Litestack::ClosedError, ThreadError
          break
        end
        waiter.sleep(0.02)
      end
    end
  end

  def create_pruner
    waiter = track_waiter
    Litescheduler.spawn do
      while @running
        begin
          run_stmt(:prune, @options[:expire_after])
        rescue Litestack::ClosedError
          break
        end
        waiter.sleep(@options[:expire_after])
      end
    end
  end

  def create_listener
    waiter = track_waiter
    Litescheduler.spawn do
      while @running
        begin
          @last_fetched_id ||= run_stmt(:last_id)[0][0] || 0
          run_stmt(:fetch, @last_fetched_id, @pid).to_a.each do |msg|
            @logger.info "RECEIVED #{msg}"
            @last_fetched_id = msg[0]
            local_broadcast(msg[1], Oj.load(msg[2]))
          end
        rescue Litestack::ClosedError
          break
        rescue Oj::ParseError => e
          @logger&.warn { "[litecable] malformed message: #{e.message}" }
        end
        waiter.sleep(@options[:listen_interval])
      end
    end
  end

  def create_honker_listener
    waiter = track_waiter
    prefix = @options[:honker_channel_prefix] || "litecable:"
    wait_s = (@options[:fallback_interval] || @options[:listen_interval] || 0.5).to_f
    wait_s = 0.5 if wait_s <= 0
    Litescheduler.spawn do
      while @running
        begin
          drained = drain_honker_notifications(prefix)
          unless drained
            @honker_db&.wait_for_update(wait_s)
          end
        rescue Litestack::ClosedError
          break
        rescue ::Honker::Error, SQLite3::Exception => e
          break unless @running
          @logger&.warn { "[litecable] honker listener: #{e.message}" }
          waiter.sleep(0.05)
        end
      end
    end
  end

  def drain_honker_notifications(prefix)
    return false unless @honker_db

    rows = @honker_db.db.execute(
      "SELECT id, channel, payload FROM _honker_notifications " \
      "WHERE id > ? AND channel LIKE ? ORDER BY id",
      [@last_notification_id, "#{prefix}%"]
    )
    return false if rows.empty?

    rows.each do |id, channel, payload_raw|
      @last_notification_id = id.to_i
      # Skip our own process? ActionCable still needs multi-process only;
      # local_broadcast already delivered in broadcast(). Filter by not
      # re-delivering if we just sent — use pid in payload envelope.
      logical_channel = channel.to_s.delete_prefix(prefix)
      payload = parse_cable_payload(payload_raw)
      # Skip our own notifies — local_broadcast already ran in #broadcast.
      if payload.is_a?(Hash) && payload.key?("_litecable_src")
        next if payload["_litecable_src"] == @instance_id
        payload = payload["data"]
      end
      local_broadcast(logical_channel, payload)
    end
    true
  end

  def parse_cable_payload(raw)
    return nil if raw.nil? || raw == "" || raw == "null"
    Oj.load(raw)
  rescue Oj::ParseError
    raw
  end

  def create_honker_pruner
    waiter = track_waiter
    Litescheduler.spawn do
      while @running
        begin
          @honker_db&.prune_notifications(older_than_s: @options[:expire_after].to_i)
        rescue
          nil
        end
        waiter.sleep([@options[:expire_after].to_f, 1.0].max)
      end
    end
  end

  def create_connection
    super("#{__dir__}/sql/litecable.sql.yml") do |conn|
      conn.wal_autocheckpoint = 10000
      # When using honker transport we still keep messages schema for fallback
      # and metrics compatibility, but load extension for optional dual-write.
      if honker_transport? && Litestack::Wakeup::Honker.watchable_path?(@options[:path])
        begin
          if Litestack::Wakeup::Honker.load_honker_gem!
            ::Honker.setup(conn, extension_path: @options[:honker_extension_path])
          end
        rescue LoadError, StandardError
          # optional — transport setup will fall back
        end
      end
    end
  end

  def close_connection_pool
    begin
      @honker_db&.close
    rescue
      nil
    end
    @honker_db = nil
    super
  end
end
