#!/usr/bin/env ruby
# frozen_string_literal: true
#
# LiteCache L1 / invalidation benchmark + regression gate.
#
# Modes:
#   baseline   — current Litecache only (L1 off). Writes JSON metrics.
#   compare    — re-run baseline metrics and fail if slower than saved JSON.
#   invalidate — two-process invalidate latency (requires honker + file path).
#   all        — baseline then invalidate (if honker available).
#
# Usage:
#   bundle exec ruby bench/bench_litecache_l1.rb baseline
#   bundle exec ruby bench/bench_litecache_l1.rb compare
#   bundle exec ruby bench/bench_litecache_l1.rb invalidate
#   bundle exec ruby bench/bench_litecache_l1.rb all
#
# Env:
#   LITESTACK_BENCH_ITERS=2000
#   LITESTACK_BENCH_VALUE_BYTES=100
#   LITESTACK_BENCH_REGRESSION=0.95   # compare must keep ≥ 95% of baseline IPS
#   LITESTACK_BENCH_OUT=bench/results/litecache_l1_baseline.json

require "json"
require "fileutils"
require "tmpdir"
require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "litestack" # full load for Litestack::* errors used on close

module LitecacheL1Bench
  module_function

  def iters
    Integer(ENV.fetch("LITESTACK_BENCH_ITERS", "2000"))
  end

  def value_bytes
    Integer(ENV.fetch("LITESTACK_BENCH_VALUE_BYTES", "100"))
  end

  def regression_floor
    Float(ENV.fetch("LITESTACK_BENCH_REGRESSION", "0.95"))
  end

  def out_path
    ENV.fetch("LITESTACK_BENCH_OUT", File.expand_path("results/litecache_l1_baseline.json", __dir__))
  end

  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def random_str(size)
    # Avoid dependency on sqlite for hex blobs in the bench harness.
    bytes = size.times.map { rand(16).to_s(16) }.join
    bytes[0, size]
  end

  # Returns { seconds:, ips:, iterations: }
  def measure(iterations)
    GC.start
    t0 = mono
    iterations.times { |i| yield i }
    t1 = mono
    elapsed = t1 - t0
    ips = (elapsed > 0) ? (iterations / elapsed) : Float::INFINITY
    {seconds: elapsed, ips: ips, iterations: iterations}
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

  def build_cache(path, **opts)
    Litecache.new({
      path: path,
      logger: nil,
      metrics: false,
      sleep_interval: 3600,
      size: 32 * 1024 * 1024,
      mmap_size: 16 * 1024 * 1024
    }.merge(opts))
  end

  def run_baseline(path: nil, l1: false)
    dir = nil
    path ||= begin
      dir = Dir.mktmpdir("litecache-bench-")
      File.join(dir, "cache.sqlite3")
    end

    cache = build_cache(path, l1: l1)
    n = iters
    vsize = value_bytes
    keys = Array.new(n) { |i| "k#{i}" }
    values = Array.new(n) { random_str(vsize) }
    # Warm schema / mmap
    cache.set("__warm", "1")
    cache.get("__warm")

    write_m = measure(n) { |i| cache.set(keys[i], values[i]) }
    # Sequential get (predictable, measures prepared stmt path)
    read_m = measure(n) { |i| cache.get(keys[i]) }
    # Random get
    order = (0...n).to_a.shuffle
    rand_m = measure(n) { |i| cache.get(keys[order[i]]) }
    del_m = measure(n / 2) { |i| cache.delete(keys[i]) }

    # Multi ops
    multi_n = [n / 10, 1].max
    multi_write = measure(multi_n) do |i|
      payload = {}
      10.times { |j| payload[keys[(i * 10 + j) % n]] = values[(i * 10 + j) % n] }
      cache.set_multi(payload)
    end
    multi_read = measure(multi_n) do |i|
      ks = 10.times.map { |j| keys[(i * 10 + j) % n] }
      cache.get_multi(*ks)
    end

    # Hot-key L1 read: same key repeatedly (only meaningful when l1: true)
    hot_m = measure(n) { cache.get(keys[0]) }

    l1_stats = l1_stats_from(cache)

    report = {
      version: 1,
      mode: l1 ? "l1_local" : "baseline",
      ruby: RUBY_DESCRIPTION,
      captured_at: Time.now.utc.iso8601,
      config: {
        iterations: n,
        value_bytes: vsize,
        path_kind: (path.to_s == ":memory:") ? "memory" : "file",
        l1: l1
      },
      metrics: {
        set_ips: write_m[:ips],
        set_seconds: write_m[:seconds],
        get_ips: read_m[:ips],
        get_seconds: read_m[:seconds],
        get_random_ips: rand_m[:ips],
        get_random_seconds: rand_m[:seconds],
        get_hot_ips: hot_m[:ips],
        get_hot_seconds: hot_m[:seconds],
        delete_ips: del_m[:ips],
        delete_seconds: del_m[:seconds],
        set_multi_ips: multi_write[:ips],
        get_multi_ips: multi_read[:ips]
      },
      l1: l1_stats,
      # Placeholders for future invalidate mode (keep schema stable)
      invalidate: {
        measured: false,
        p50_ms: nil,
        p99_ms: nil,
        samples: 0
      }
    }

    safe_close(cache)
    FileUtils.rm_rf(dir) if dir
    report
  end

  def safe_close(cache)
    return unless cache

    cache.close(timeout: 2)
  rescue Litestack::ShutdownTimeoutError, Litestack::ClosedError
    nil
  end

  def l1_stats_from(cache)
    if cache.respond_to?(:l1_stats)
      cache.l1_stats
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

  def save_report(report, path = out_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(report))
    path
  end

  def load_report(path = out_path)
    JSON.parse(File.read(path))
  end

  def compare_reports(baseline, current, floor: regression_floor)
    failures = []
    %w[set_ips get_ips get_random_ips delete_ips].each do |key|
      b = baseline.dig("metrics", key) || baseline.dig(:metrics, key)
      c = current.dig("metrics", key) || current.dig(:metrics, key)
      next if b.nil? || c.nil? || b.to_f <= 0

      ratio = c.to_f / b.to_f
      if ratio < floor
        failures << format("%s: current %.1f ips is %.1f%% of baseline %.1f (floor %.0f%%)",
          key, c, ratio * 100, b, floor * 100)
      end
    end
    failures
  end

  def print_report(report)
    m = report[:metrics] || report["metrics"]
    puts "LiteCache bench (#{report[:mode] || report["mode"]})"
    cfg = report[:config] || report["config"]
    if cfg
      puts "  iterations=#{cfg[:iterations] || cfg["iterations"]} " \
           "value_bytes=#{cfg[:value_bytes] || cfg["value_bytes"]}"
    end
    if m
      %w[set_ips get_ips get_random_ips get_hot_ips delete_ips set_multi_ips get_multi_ips].each do |k|
        v = m[k.to_sym] || m[k]
        next unless v

        puts format("  %-16s %10.1f ips", k, v)
      end
    end
    inv = report[:invalidate] || report["invalidate"]
    if inv && (inv[:measured] || inv["measured"])
      puts format("  invalidate kind   %10s", (inv[:kind] || inv["kind"]).to_s)
      puts format("  invalidate p50    %10.3f ms", (inv[:p50_ms] || inv["p50_ms"]).to_f)
      puts format("  invalidate p99    %10.3f ms", (inv[:p99_ms] || inv["p99_ms"]).to_f)
      puts format("  invalidate max    %10.3f ms", (inv[:max_ms] || inv["max_ms"]).to_f)
      puts format("  invalidate n      %10d", (inv[:samples] || inv["samples"]).to_i)
    end
    l1 = report[:l1] || report["l1"]
    if l1
      en = l1.key?(:enabled) ? l1[:enabled] : l1["enabled"]
      hr = l1[:hit_rate] || l1["hit_rate"]
      mode = l1[:invalidate_mode] || l1["invalidate_mode"]
      puts "  l1.enabled=#{en.inspect} hit_rate=#{hr} mode=#{mode}"
    end
  end

  # Cross-process L1 drop latency with invalidate: :honker.
  # Reader warms L1, writer overwrites key, reader waits until L1 misses.
  def run_invalidate(samples: 50)
    unless honker_available?
      return {
        version: 1,
        mode: "invalidate",
        skipped: true,
        reason: "honker gem / extension unavailable",
        invalidate: {measured: false}
      }
    end

    dir = Dir.mktmpdir("litecache-inv-")
    path = File.join(dir, "cache.sqlite3")

    begin
      reader_ready = File.join(dir, "ready")
      lat_file = File.join(dir, "latencies.json")

      reader = fork do
        cache = build_cache(
          path,
          l1: true,
          invalidate: :honker,
          l1_ttl: 120,
          watcher_poll_interval_ms: 5
        )
        latencies_ms = []
        File.write(reader_ready, "1")
        samples.times do |i|
          key = "inv-#{i}"
          # Wait until L2 has initial value and fill L1
          t0 = mono
          loop do
            val = cache.get(key)
            break if val == "old-#{i}"
            raise "timeout waiting for seed" if mono - t0 > 3
            sleep 0.001
          end
          # Confirm L1 hit
          hit, = cache.instance_variable_get(:@l1).fetch(key)
          raise "L1 not warm" unless hit

          # Wait for L1 drop after writer overwrites
          t_wait0 = mono
          loop do
            hit, = cache.instance_variable_get(:@l1).fetch(key)
            unless hit
              latencies_ms << (mono - t_wait0) * 1000.0
              break
            end
            if mono - t_wait0 > 2.0
              latencies_ms << (mono - t_wait0) * 1000.0
              break
            end
            sleep 0.0005
          end
        end
        File.write(lat_file, JSON.generate(latencies_ms))
        begin
          cache.close(timeout: 2)
        rescue
          nil
        end
        exit! 0
      end

      deadline = mono + 5
      until File.exist?(reader_ready)
        raise "reader failed to start" if mono > deadline
        sleep 0.01
      end

      writer = build_cache(
        path,
        l1: true,
        invalidate: :honker,
        l1_ttl: 120,
        watcher_poll_interval_ms: 5
      )
      samples.times do |i|
        key = "inv-#{i}"
        writer.set(key, "old-#{i}")
        # Let reader warm L1
        sleep 0.01
        writer.set(key, "new-#{i}")
      end
      safe_close(writer)

      Process.wait(reader)
      latencies_ms = JSON.parse(File.read(lat_file))
      sorted = latencies_ms.map(&:to_f).sort
      {
        version: 1,
        mode: "invalidate",
        skipped: false,
        captured_at: Time.now.utc.iso8601,
        invalidate: {
          measured: true,
          kind: "l1_drop",
          samples: sorted.size,
          p50_ms: percentile(sorted, 50),
          p99_ms: percentile(sorted, 99),
          max_ms: sorted.last,
          mean_ms: sorted.empty? ? 0 : (sorted.sum / sorted.size)
        }
      }
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  def honker_available?
    require "honker"
    defined?(::Honker::Database)
  rescue LoadError
    false
  end

  def main(argv)
    mode = argv[0] || "all"
    case mode
    when "baseline"
      report = run_baseline(l1: false)
      print_report(report)
      path = save_report(report)
      puts "Wrote #{path}"
    when "l1_local"
      report = run_baseline(l1: true)
      print_report(report)
      path = save_report(report, File.expand_path("results/litecache_l1_local.json", __dir__))
      puts "Wrote #{path}"
      # Report hot vs sequential get ratio when L1 is warm
      m = report[:metrics]
      if m[:get_ips].to_f > 0 && m[:get_hot_ips].to_f > 0
        puts format("  hot/seq get ratio  %10.2fx", m[:get_hot_ips] / m[:get_ips])
      end
    when "compare"
      unless File.file?(out_path)
        warn "No baseline at #{out_path}; run: #{$PROGRAM_NAME} baseline"
        exit 1
      end
      baseline = load_report
      # Always compare the default-off L2 path (regression gate for merges)
      current = run_baseline(l1: false)
      print_report(current)
      failures = compare_reports(baseline, current)
      if failures.empty?
        puts "OK: no regression vs #{out_path} (floor #{(regression_floor * 100).to_i}%)"
      else
        warn "REGRESSION:"
        failures.each { |f| warn "  - #{f}" }
        exit 2
      end
    when "invalidate"
      report = run_invalidate
      if report[:skipped] || report["skipped"]
        puts "invalidate skipped: #{report[:reason] || report["reason"]}"
        exit 0
      end
      print_report(report)
      path = save_report(report, File.expand_path("results/litecache_invalidate.json", __dir__))
      puts "Wrote #{path}"
    when "all"
      base = run_baseline(l1: false)
      print_report(base)
      save_report(base)
      puts "Wrote #{out_path}"
      l1 = run_baseline(l1: true)
      print_report(l1)
      save_report(l1, File.expand_path("results/litecache_l1_local.json", __dir__))
      m = l1[:metrics]
      if m[:get_ips].to_f > 0 && m[:get_hot_ips].to_f > 0
        puts format("  hot/seq get ratio  %10.2fx", m[:get_hot_ips] / m[:get_ips])
      end
      inv = run_invalidate
      unless inv[:skipped] || inv["skipped"]
        print_report(inv)
        save_report(inv, File.expand_path("results/litecache_invalidate.json", __dir__))
      end
    when "help", "-h", "--help"
      puts <<~HELP
        Usage: #{$PROGRAM_NAME} [baseline|l1_local|compare|invalidate|all]

        baseline   Measure Litecache with L1 off; write JSON baseline
        l1_local   Measure with L1 on (same-process); report hot-key get IPS
        compare    Re-measure L1-off path; exit 2 if IPS < LITESTACK_BENCH_REGRESSION of baseline
        invalidate Cross-process L2 visibility / future L1 invalidate latency
        all        baseline + l1_local + invalidate
      HELP
    else
      warn "Unknown mode #{mode.inspect}"
      exit 1
    end
  end
end

LitecacheL1Bench.main(ARGV) if $PROGRAM_NAME == __FILE__
