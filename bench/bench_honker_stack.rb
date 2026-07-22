#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Substantial multi-process benchmark: LiteJob + LiteCache + LiteCable
# with Honker fully activated vs polling / no-L1 baselines.
#
# Prerequisites:
#   gem "honker" installed (GitHub Packages)
#   File-backed SQLite paths (not :memory:)
#
# Usage:
#   bundle exec ruby bench/bench_honker_stack.rb
#   bundle exec ruby bench/bench_honker_stack.rb --jobs 200 --cache-keys 100 --cable-msgs 80
#   LITESTACK_BENCH_OUT=bench/results/honker_stack.json bundle exec rake bench:honker_stack
#
# Exit 0 always writes a report; exit 1 if honker missing or assertions fail.

require "optparse"
require "json"
require "fileutils"
require "tmpdir"
require "securerandom"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "litestack"

module HonkerStackBench
  module_function

  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def percentile(sorted, p)
    return nil if sorted.empty?
    return sorted.first if sorted.size == 1

    rank = (p / 100.0) * (sorted.size - 1)
    lo = rank.floor
    hi = rank.ceil
    return sorted[lo] if lo == hi

    sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo)
  end

  def pct_summary(lat_ms)
    s = lat_ms.sort
    {
      n: s.size,
      p50_ms: percentile(s, 50)&.round(3),
      p95_ms: percentile(s, 95)&.round(3),
      p99_ms: percentile(s, 99)&.round(3),
      max_ms: s.last&.round(3),
      mean_ms: s.empty? ? nil : (s.sum / s.size).round(3)
    }
  end

  def thruput(n, seconds)
    return 0.0 if seconds <= 0

    (n / seconds.to_f).round(1)
  end

  def honker_ok?
    Litestack::Wakeup::Honker.load_honker_gem!
  end

  # --- LiteJob: enqueue N jobs, measure wall time to complete with workers ---
  def bench_jobs(dir, mode:, jobs:, workers:)
    path = File.join(dir, "queue-#{mode}.sqlite3")
    done_file = File.join(dir, "jobs-#{mode}.txt")
    File.write(done_file, "")

    Object.send(:remove_const, :HonkerStackBenchJob) if defined?(HonkerStackBenchJob)
    Object.const_set(:HonkerStackBenchJob, Class.new do
      def perform(i)
        File.open(ENV.fetch("HSB_DONE"), "a") { |f| f.puts(i) }
      end
    end)

    ENV["HSB_DONE"] = done_file

    # Tight fallback so a missed notify is not measured as a 1s stall.
    # (fallback_interval is a safety net, not the primary wake path.)
    opts_common = {
      path: path,
      workers: 0,
      queues: [["default", 1]],
      logger: nil,
      leadership: false,
      lifecycle_stream: false,
      job_results: false,
      retries: 1,
      sleep_intervals: [0.001, 0.005, 0.02],
      fallback_interval: 0.05
    }

    # Modes:
    #   :polling — destructive pop + sleep polling (max throughput baseline)
    #   :honker  — claim/ack + wakeup:honker + filtered notify (production-like)
    #   :honker_backend_only — claim/ack + polling wake (isolates claim cost)
    honker_backend = mode.to_s.start_with?("honker")
    honker_wake = (mode == :honker)
    worker_opts = opts_common.merge(
      workers: 1,
      backend: honker_backend ? :honker : :litequeue,
      wakeup: honker_wake ? :honker : :polling,
      watcher_poll_interval_ms: 5,
      visibility_timeout: 30,
      heartbeat_interval: 0,
      queue_notify: honker_wake,
      wakeup_filter_notifications: honker_wake
    )

    pids = workers.times.map do |w|
      fork do
        $0 = "hsb-job-worker-#{mode}-#{w}"
        Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
        q = Litejobqueue.jobqueue(worker_opts)
        # Stay alive until parent kills us
        sleep 3600
        q.stop
      rescue => e
        warn "worker: #{e.class}: #{e.message}"
        exit! 2
      end
    end

    sleep 0.25
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    producer = Litejobqueue.jobqueue(opts_common.merge(
      backend: honker_backend ? :honker : :litequeue,
      wakeup: honker_wake ? :honker : :polling,
      queue_notify: honker_wake,
      wakeup_filter_notifications: honker_wake
    ))

    # Time only enqueue → all jobs done. Do NOT include producer.stop / worker
    # teardown (Honker sweep-thread join previously inflated wall by ~1s).
    t0 = mono
    jobs.times { |i| producer.push("HonkerStackBenchJob", [i], 0, "default") }

    deadline = t0 + [jobs * 0.5, 60].max
    loop do
      n = File.readlines(done_file).size
      break if n >= jobs
      if mono > deadline
        pids.each { |pid| Process.kill("TERM", pid) rescue nil }
        pids.each { |pid| Process.wait(pid) rescue nil }
        begin
          producer.stop
        rescue
          nil
        end
        return {mode: mode.to_s, ok: false, error: "timeout got #{n}/#{jobs}"}
      end
      sleep 0.005
    end
    t1 = mono

    begin
      producer.stop
    rescue
      nil
    end
    pids.each { |pid| Process.kill("TERM", pid) rescue nil }
    pids.each { |pid| Process.wait(pid) rescue nil }

    elapsed = t1 - t0
    completed = File.readlines(done_file).map(&:strip).uniq.size
    {
      mode: mode.to_s,
      ok: completed >= jobs,
      jobs: jobs,
      workers: workers,
      completed_unique: completed,
      wall_seconds: elapsed.round(4),
      jobs_per_sec: thruput(jobs, elapsed),
      backend: honker_backend ? "honker" : "litequeue",
      wakeup: honker_wake ? "honker" : "polling"
    }
  ensure
    Object.send(:remove_const, :HonkerStackBenchJob) if defined?(HonkerStackBenchJob)
  end

  # --- LiteCache: L1 local IPS + multi-process invalidate latency ---
  def bench_cache(dir, keys:, value_bytes:)
    path = File.join(dir, "cache.sqlite3")
    value = "x" * value_bytes

    # A) no L1 baseline hot get
    c0 = Litecache.new(path: path, logger: nil, sleep_interval: 3600, l1: false, invalidate: :none)
    c0.set("hot", value)
    n = [keys * 20, 500].max
    t0 = mono
    n.times { c0.get("hot") }
    no_l1_ips = thruput(n, mono - t0)
    c0.close(timeout: 2) rescue nil

    # B) L1 local hot get
    c1 = Litecache.new(
      path: path, logger: nil, sleep_interval: 3600,
      l1: true, invalidate: :honker, l1_ttl: 120, watcher_poll_interval_ms: 5
    )
    c1.set("hot", value)
    c1.get("hot") # warm
    t0 = mono
    n.times { c1.get("hot") }
    l1_ips = thruput(n, mono - t0)
    l1_stats = c1.l1_stats
    c1.close(timeout: 2) rescue nil

    # C) cross-process invalidate latency
    inv_file = File.join(dir, "inv_lat.json")
    seed_done = File.join(dir, "cache.seeded")
    warm_done = File.join(dir, "cache.warm")
    upd_done = File.join(dir, "cache.updated")

    reader = fork do
      $0 = "hsb-cache-reader"
      cache = Litecache.new(
        path: path, logger: nil, sleep_interval: 3600,
        l1: true, invalidate: :honker, l1_ttl: 120, watcher_poll_interval_ms: 5
      )
      t = mono
      loop { break if File.exist?(seed_done); raise "seed timeout" if mono - t > 15; sleep 0.01 }
      keys.times do |i|
        k = "ck#{i}"
        t1 = mono
        loop do
          break if cache.get(k) == "seed-#{i}"
          raise "seed #{k}" if mono - t1 > 5
          sleep 0.002
        end
        hit, = cache.instance_variable_get(:@l1).fetch(k)
        raise "L1 cold #{k}" unless hit
      end
      File.write(warm_done, "1")
      t = mono
      loop { break if File.exist?(upd_done); raise "upd timeout" if mono - t > 20; sleep 0.01 }
      lats = []
      keys.times do |i|
        k = "ck#{i}"
        t2 = mono
        loop do
          hit, = cache.instance_variable_get(:@l1).fetch(k)
          unless hit
            lats << (mono - t2) * 1000.0
            break
          end
          raise "drop timeout #{k}" if mono - t2 > 5
          sleep 0.001
        end
        t3 = mono
        loop do
          break if cache.get(k) == "new-#{i}"
          raise "stale #{k}" if mono - t3 > 5
          sleep 0.002
        end
      end
      File.write(inv_file, JSON.generate(lats))
      cache.close(timeout: 2) rescue nil
      exit! 0
    end

    sleep 0.3
    writer = Litecache.new(
      path: path, logger: nil, sleep_interval: 3600,
      l1: true, invalidate: :honker, l1_ttl: 120, watcher_poll_interval_ms: 5
    )
    keys.times { |i| writer.set("ck#{i}", "seed-#{i}") }
    File.write(seed_done, "1")
    t = mono
    loop { break if File.exist?(warm_done); raise "warm timeout" if mono - t > 20; sleep 0.01 }
    keys.times { |i| writer.set("ck#{i}", "new-#{i}") }
    File.write(upd_done, "1")
    writer.close(timeout: 2) rescue nil
    Process.wait(reader)
    raise "cache reader failed" unless $?.success?

    lats = JSON.parse(File.read(inv_file)).map(&:to_f)
    {
      ok: true,
      no_l1_hot_get_ips: no_l1_ips,
      l1_hot_get_ips: l1_ips,
      l1_speedup: (no_l1_ips > 0) ? (l1_ips / no_l1_ips.to_f).round(2) : nil,
      l1_stats: l1_stats,
      invalidate: pct_summary(lats).merge(kind: "honker")
    }
  end

  # --- LiteCable: cross-process broadcast latency ---
  def bench_cable(dir, messages:)
    poll = measure_cable(File.join(dir, "cable-poll.sqlite3"), messages, transport: :polling)
    honk = measure_cable(File.join(dir, "cable-honk.sqlite3"), messages, transport: :honker)
    {
      ok: poll[:ok] && honk[:ok],
      polling: poll,
      honker: honk,
      p50_speedup: if poll.dig(:latency, :p50_ms).to_f > 0 && honk.dig(:latency, :p50_ms).to_f > 0
                     (poll[:latency][:p50_ms] / honk[:latency][:p50_ms]).round(2)
                   end
    }
  end

  def measure_cable(path, messages, transport:)
    ready = path + ".ready"
    lat_file = path + ".lat.json"
    FileUtils.rm_f([ready, lat_file])
    FileUtils.touch(path)

    sub = fork do
      $0 = "hsb-cable-sub-#{transport}"
      cable = Litecable.new(
        path: path, logger: nil, metrics: false, leadership: false,
        transport: transport, watcher_poll_interval_ms: 5, listen_interval: 0.01
      )
      lats = []
      got = 0
      # subscribe(channel, callable) — not a block
      cable.subscribe("bench", lambda { |payload|
        s = payload.is_a?(Hash) ? (payload["t"] || payload[:t]).to_s : payload.to_s
        # payload format: "seq|mono_t0"
        _seq, t0_s = s.to_s.split("|", 2)
        if t0_s
          lats << (mono - t0_s.to_f) * 1000.0
          got += 1
        end
      })
      File.write(ready, "1")
      # Polling default listen_interval is 50ms — allow headroom after last publish.
      deadline = mono + 90
      loop do
        break if got >= messages
        break if mono > deadline
        sleep 0.005
      end
      File.write(lat_file, JSON.generate(lats))
      begin
        cable.close
      rescue
        nil
      end
      exit! 0
    end

    t = mono
    loop do
      break if File.exist?(ready)
      if mono - t > 15
        Process.kill("TERM", sub) rescue nil
        Process.wait(sub) rescue nil
        return {ok: false, transport: transport.to_s, error: "subscriber ready timeout"}
      end
      sleep 0.01
    end
    sleep 0.15 # listeners attach

    pub = Litecable.new(
      path: path, logger: nil, metrics: false, leadership: false,
      transport: transport, watcher_poll_interval_ms: 5, listen_interval: 0.01
    )
    t_pub0 = mono
    messages.times do |i|
      pub.broadcast("bench", "#{i}|#{mono}")
      sleep 0.002
    end
    # Give polling listener time to drain the message table
    sleep(transport == :polling ? 1.0 : 0.2)
    pub_elapsed = mono - t_pub0
    begin
      pub.close
    rescue
      nil
    end

    Process.wait(sub)
    lats = File.file?(lat_file) ? JSON.parse(File.read(lat_file)).map(&:to_f) : []
    # Accept ≥80% delivery for micro-bench stability under load
    min_ok = (messages * 0.8).ceil
    {
      ok: lats.size >= min_ok,
      transport: transport.to_s,
      messages: messages,
      received: lats.size,
      publish_msg_per_sec: thruput(messages, pub_elapsed),
      latency: pct_summary(lats)
    }
  rescue => e
    if defined?(sub) && sub
      begin
        Process.kill("TERM", sub)
      rescue
        nil
      end
      begin
        Process.wait(sub)
      rescue
        nil
      end
    end
    {ok: false, transport: transport.to_s, error: "#{e.class}: #{e.message}"}
  end

  def run!(opts)
    unless honker_ok?
      warn "FAIL: honker gem not loadable — install from GitHub Packages"
      return 1
    end

    dir = Dir.mktmpdir("honker-stack-bench-")
    report = {
      version: 1,
      captured_at: Time.now.utc.iso8601,
      ruby: RUBY_DESCRIPTION,
      honker: (defined?(Honker::VERSION) ? Honker::VERSION.to_s : "loaded"),
      config: opts,
      components: {}
    }

    puts "=== Honker stack benchmark ==="
    puts "  jobs=#{opts[:jobs]} workers=#{opts[:workers]} cache_keys=#{opts[:cache_keys]} cable_msgs=#{opts[:cable_msgs]}"
    puts

    # Status probe first
    status = Litestack::HonkerStatus.check(path: File.join(dir, "probe.sqlite3"), live: true)
    report[:status] = status
    puts Litestack::HonkerStatus.format(status)
    puts

    puts "--- LiteJob (polling vs honker full vs claim-only) ---"
    j_poll = bench_jobs(dir, mode: :polling, jobs: opts[:jobs], workers: opts[:workers])
    j_honk = bench_jobs(dir, mode: :honker, jobs: opts[:jobs], workers: opts[:workers])
    j_claim = bench_jobs(dir, mode: :honker_backend_only, jobs: opts[:jobs], workers: opts[:workers])
    report[:components][:litejob] = {
      polling: j_poll,
      honker: j_honk,
      honker_backend_only: j_claim
    }
    if j_poll[:ok] && j_honk[:ok] && j_poll[:jobs_per_sec].to_f > 0
      report[:components][:litejob][:ratio_honker_full] =
        (j_honk[:jobs_per_sec] / j_poll[:jobs_per_sec].to_f).round(2)
    end
    if j_poll[:ok] && j_claim[:ok] && j_poll[:jobs_per_sec].to_f > 0
      report[:components][:litejob][:ratio_honker_claim_only] =
        (j_claim[:jobs_per_sec] / j_poll[:jobs_per_sec].to_f).round(2)
    end
    puts "  polling (pop):           #{j_poll[:jobs_per_sec]} jobs/s  wall=#{j_poll[:wall_seconds]}s  ok=#{j_poll[:ok]}"
    puts "  honker full (claim+wake):#{j_honk[:jobs_per_sec]} jobs/s  wall=#{j_honk[:wall_seconds]}s  ok=#{j_honk[:ok]}  ratio=#{report.dig(:components, :litejob, :ratio_honker_full)}×"
    puts "  honker claim + poll wake:#{j_claim[:jobs_per_sec]} jobs/s  wall=#{j_claim[:wall_seconds]}s  ok=#{j_claim[:ok]}  ratio=#{report.dig(:components, :litejob, :ratio_honker_claim_only)}×"
    puts "  note: claim/ack does more SQL/job than destructive pop; full mode needs enqueue notify (fixed)"
    puts

    # Keep ok check compatible
    j_poll_ok = j_poll
    j_honk_ok = j_honk

    puts "--- LiteCache (L1 + honker invalidate) ---"
    cache = bench_cache(dir, keys: opts[:cache_keys], value_bytes: opts[:value_bytes])
    report[:components][:litecache] = cache
    puts "  no-L1 hot get: #{cache[:no_l1_hot_get_ips]} ips"
    puts "  L1 hot get:    #{cache[:l1_hot_get_ips]} ips  (#{cache[:l1_speedup]}×)"
    inv = cache[:invalidate]
    puts "  invalidate p50=#{inv[:p50_ms]}ms p99=#{inv[:p99_ms]}ms n=#{inv[:n]}"
    puts

    puts "--- LiteCable (polling vs honker) ---"
    cable = bench_cable(dir, messages: opts[:cable_msgs])
    report[:components][:litecable] = cable
    if cable[:polling]
      puts "  polling p50=#{cable.dig(:polling, :latency, :p50_ms)}ms p99=#{cable.dig(:polling, :latency, :p99_ms)}ms"
    end
    if cable[:honker]
      puts "  honker  p50=#{cable.dig(:honker, :latency, :p50_ms)}ms p99=#{cable.dig(:honker, :latency, :p99_ms)}ms"
    end
    puts "  p50 speedup (poll/honker): #{cable[:p50_speedup]}×"
    puts

    out = opts[:out]
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, JSON.pretty_generate(report))
    puts "Wrote #{out}"

    ok = status[:ok] &&
      j_poll_ok[:ok] && j_honk_ok[:ok] && j_claim[:ok] &&
      cache[:ok] &&
      cable[:ok]
    puts ok ? "=== BENCH OK ===" : "=== BENCH HAD FAILURES ==="
    ok ? 0 : 1
  ensure
    FileUtils.rm_rf(dir) if dir && ENV["LITESTACK_BENCH_KEEP"] != "1"
  end
end

opts = {
  jobs: Integer(ENV.fetch("LITESTACK_BENCH_JOBS", "120")),
  workers: Integer(ENV.fetch("LITESTACK_BENCH_WORKERS", "2")),
  cache_keys: Integer(ENV.fetch("LITESTACK_BENCH_CACHE_KEYS", "40")),
  cable_msgs: Integer(ENV.fetch("LITESTACK_BENCH_CABLE_MSGS", "40")),
  value_bytes: Integer(ENV.fetch("LITESTACK_BENCH_VALUE_BYTES", "100")),
  out: ENV.fetch("LITESTACK_BENCH_OUT", File.expand_path("results/honker_stack.json", __dir__))
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options]"
  o.on("--jobs N", Integer) { |v| opts[:jobs] = v }
  o.on("--workers N", Integer) { |v| opts[:workers] = v }
  o.on("--cache-keys N", Integer) { |v| opts[:cache_keys] = v }
  o.on("--cable-msgs N", Integer) { |v| opts[:cable_msgs] = v }
  o.on("--value-bytes N", Integer) { |v| opts[:value_bytes] = v }
  o.on("--out PATH") { |v| opts[:out] = v }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

exit HonkerStackBench.run!(opts)
