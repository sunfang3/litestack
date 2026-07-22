#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Finite multi-process soak for Honker-backed paths.
#
# Covers:
#   * LiteJob backend: :honker claim/ack (+ optional long-job heartbeat)
#   * LiteCache L1 + invalidate: :honker peer drop
#
# Usage:
#   bundle exec ruby scripts/soak_honker.rb
#   bundle exec ruby scripts/soak_honker.rb --duration 20 --jobs 40
#
# Exit 0 on success; non-zero on assertion failure.
# Skips (exit 0) when honker cannot load (missing gem/extension).

require "optparse"
require "tmpdir"
require "fileutils"
require "json"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "litestack"

opts = {
  duration: Integer(ENV.fetch("LITESTACK_SOAK_DURATION", "15")),
  jobs: Integer(ENV.fetch("LITESTACK_SOAK_JOBS", "30")),
  cache_keys: Integer(ENV.fetch("LITESTACK_SOAK_CACHE_KEYS", "20"))
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options]"
  o.on("--duration SEC", Integer, "Wall seconds for job workers (default #{opts[:duration]})") { |v| opts[:duration] = v }
  o.on("--jobs N", Integer, "Jobs to enqueue (default #{opts[:jobs]})") { |v| opts[:jobs] = v }
  o.on("--cache-keys N", Integer, "Cache keys for invalidate soak (default #{opts[:cache_keys]})") { |v| opts[:cache_keys] = v }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

def mono
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def fail!(msg)
  warn "SOAK FAIL: #{msg}"
  exit 1
end

def ok!(msg)
  puts "SOAK OK: #{msg}"
end

unless Litestack::Wakeup::Honker.load_honker_gem!
  puts "SOAK SKIP: honker gem/extension not available"
  exit 0
end

dir = Dir.mktmpdir("litestack-soak-")
queue_path = File.join(dir, "queue.sqlite3")
cache_path = File.join(dir, "cache.sqlite3")
result_path = File.join(dir, "results.json")
errors = []

begin
  # --- LiteJob multi-process: producer + 2 workers ---
  job_count = opts[:jobs]
  done_marker = File.join(dir, "jobs.done")

  # Define a job class name workers can const_get
  Object.const_set(:SoakHonkerJob, Class.new do
    def perform(i)
      # brief work; some jobs slightly longer to exercise heartbeat path lightly
      sleep((i % 5) == 0 ? 0.15 : 0.02)
      File.open(ENV.fetch("SOAK_RESULT_PATH"), "a") { |f| f.puts(i) }
    end
  end)

  ENV["SOAK_RESULT_PATH"] = File.join(dir, "job_ids.txt")
  File.write(ENV["SOAK_RESULT_PATH"], "")

  workers = 2.times.map do |w|
    fork do
      $0 = "soak-litejob-worker-#{w}"
      q = Litejobqueue.jobqueue(
        path: queue_path,
        backend: :honker,
        wakeup: :honker,
        watcher_poll_interval_ms: 5,
        visibility_timeout: 10,
        heartbeat_interval: 2,
        workers: 1,
        queues: [["default", 1]],
        retries: 1,
        logger: nil,
        leadership: false,
        lifecycle_stream: false,
        job_results: false,
        sleep_intervals: [0.01, 0.05],
        fallback_interval: 1
      )
      # Keep process alive for duration so workers process
      sleep opts[:duration]
      q.stop
    rescue => e
      warn "worker #{w}: #{e.class}: #{e.message}"
      exit! 2
    end
  end

  # Give workers a moment to open DB
  sleep 0.3

  producer = fork do
    $0 = "soak-litejob-producer"
    q = Litejobqueue.jobqueue(
      path: queue_path,
      backend: :honker,
      wakeup: :honker,
      workers: 0,
      queues: [["default", 1]],
      logger: nil,
      leadership: false,
      lifecycle_stream: false,
      job_results: false
    )
    job_count.times { |i| q.push("SoakHonkerJob", [i], 0, "default") }
    q.stop
    File.write(done_marker, "1")
  end

  Process.wait(producer)
  fail!("producer failed") unless $?.success?

  # Wait until all job ids recorded or timeout
  deadline = mono + opts[:duration] + 10
  loop do
    lines = File.readlines(ENV["SOAK_RESULT_PATH"]).map(&:strip).reject(&:empty?)
    break if lines.size >= job_count
    fail!("timeout waiting for jobs (got #{lines.size}/#{job_count})") if mono > deadline
    sleep 0.1
  end

  lines = File.readlines(ENV["SOAK_RESULT_PATH"]).map(&:strip).reject(&:empty?)
  unique = lines.uniq
  if unique.size < job_count
    fail!("missing jobs: expected #{job_count} unique, got #{unique.size} (lines=#{lines.size})")
  end
  # At-least-once may duplicate a few; cap excess
  if lines.size > job_count * 2
    fail!("excessive duplicates: #{lines.size} executions for #{job_count} jobs")
  end
  ok!("LiteJob honker: #{unique.size} jobs completed (#{lines.size} executions)")

  workers.each do |pid|
    Process.kill("TERM", pid) rescue nil
  end
  workers.each { |pid| Process.wait(pid) rescue nil }

  # --- LiteCache L1 invalidate across processes ---
  # Phased protocol avoids seed→new races on slow CI runners:
  #   1) writer seeds all keys  2) reader warms L1  3) writer updates
  #   4) reader waits for L1 drop + durable "new-*" value
  keys = opts[:cache_keys]
  inv_lat_file = File.join(dir, "inv_lat.json")
  seed_done = File.join(dir, "cache.seeded")
  warm_done = File.join(dir, "cache.warm")
  update_done = File.join(dir, "cache.updated")

  reader = fork do
    $0 = "soak-cache-reader"
    cache = Litecache.new(
      path: cache_path,
      logger: nil,
      sleep_interval: 3600,
      l1: true,
      invalidate: :honker,
      l1_ttl: 120,
      watcher_poll_interval_ms: 5
    )
    latencies = []

    t0 = mono
    loop do
      break if File.exist?(seed_done)
      fail!("cache seed barrier timeout") if mono - t0 > 10
      sleep 0.01
    end

    keys.times do |i|
      key = "k#{i}"
      t1 = mono
      loop do
        break if cache.get(key) == "seed-#{i}"
        fail!("cache seed timeout #{key}") if mono - t1 > 5
        sleep 0.005
      end
      hit, = cache.instance_variable_get(:@l1).fetch(key)
      fail!("L1 not warm for #{key}") unless hit
    end
    File.write(warm_done, "1")

    t2 = mono
    loop do
      break if File.exist?(update_done)
      fail!("cache update barrier timeout") if mono - t2 > 15
      sleep 0.01
    end

    keys.times do |i|
      key = "k#{i}"
      t3 = mono
      loop do
        hit, = cache.instance_variable_get(:@l1).fetch(key)
        unless hit
          latencies << (mono - t3) * 1000.0
          break
        end
        fail!("L1 drop timeout #{key}") if mono - t3 > 5
        sleep 0.002
      end
      t4 = mono
      val = nil
      loop do
        val = cache.get(key)
        break if val == "new-#{i}"
        fail!("stale value for #{key}: #{val.inspect}") if mono - t4 > 5
        sleep 0.005
      end
    end
    File.write(inv_lat_file, JSON.generate(latencies))
    cache.close(timeout: 2) rescue nil
    exit! 0
  end

  sleep 0.3
  writer = Litecache.new(
    path: cache_path,
    logger: nil,
    sleep_interval: 3600,
    l1: true,
    invalidate: :honker,
    l1_ttl: 120,
    watcher_poll_interval_ms: 5
  )
  keys.times { |i| writer.set("k#{i}", "seed-#{i}") }
  File.write(seed_done, "1")

  t_warm = mono
  loop do
    break if File.exist?(warm_done)
    fail!("reader warm barrier timeout") if mono - t_warm > 15
    sleep 0.01
  end

  keys.times { |i| writer.set("k#{i}", "new-#{i}") }
  File.write(update_done, "1")
  writer.close(timeout: 2) rescue nil

  Process.wait(reader)
  fail!("cache reader failed") unless $?.success?

  lats = JSON.parse(File.read(inv_lat_file)).map(&:to_f).sort
  p50 = lats[lats.size / 2]
  p99 = lats[[(lats.size * 0.99).ceil - 1, 0].max]
  fail!("invalidate p99 too high: #{p99}ms") if p99 > 200
  ok!("LiteCache L1 drop: n=#{lats.size} p50=#{p50.round(2)}ms p99=#{p99.round(2)}ms")

  File.write(result_path, JSON.pretty_generate(
    jobs: job_count,
    job_executions: lines.size,
    cache_keys: keys,
    invalidate_p50_ms: p50,
    invalidate_p99_ms: p99
  ))
  puts "Wrote #{result_path}"
  ok!("all soak checks passed")
rescue => e
  fail!("#{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
ensure
  FileUtils.rm_rf(dir) if dir && ENV["LITESTACK_SOAK_KEEP"] != "1"
  Object.send(:remove_const, :SoakHonkerJob) if defined?(SoakHonkerJob)
end
