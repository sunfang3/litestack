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
require "litestack/litecache"

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

  def run_baseline(path: nil)
    dir = nil
    path ||= begin
      dir = Dir.mktmpdir("litecache-bench-")
      File.join(dir, "cache.sqlite3")
    end

    cache = build_cache(path)
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

    # L1-ready counters (always zero until L1 ships; stable schema for compare)
    l1_stats = l1_stats_from(cache)

    report = {
      version: 1,
      mode: "baseline",
      ruby: RUBY_DESCRIPTION,
      captured_at: Time.now.utc.iso8601,
      config: {
        iterations: n,
        value_bytes: vsize,
        path_kind: (path.to_s == ":memory:") ? "memory" : "file"
      },
      metrics: {
        set_ips: write_m[:ips],
        set_seconds: write_m[:seconds],
        get_ips: read_m[:ips],
        get_seconds: read_m[:seconds],
        get_random_ips: rand_m[:ips],
        get_random_seconds: rand_m[:seconds],
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

    cache.close
    FileUtils.rm_rf(dir) if dir
    report
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
      %w[set_ips get_ips get_random_ips delete_ips set_multi_ips get_multi_ips].each do |k|
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

  # Cross-process invalidation latency.
  # Today LiteCache has no L1: we measure "writer set visible to peer get"
  # as the coherence floor Honker+L1 must not exceed by much, and as a
  # template for L1 drop latency once implemented.
  def run_invalidate(samples: 100)
    unless honker_available?
      return {
        version: 1,
        mode: "invalidate",
        skipped: true,
        reason: "honker gem / extension unavailable",
        invalidate: {measured: false}
      }
    end

    require "honker"

    dir = Dir.mktmpdir("litecache-inv-")
    path = File.join(dir, "cache.sqlite3")
    latencies_ms = []

    begin
      reader_ready = File.join(dir, "ready")
      writer_done = File.join(dir, "done")
      lat_file = File.join(dir, "latencies.json")

      reader = fork do
        cache = build_cache(path)
        # Optional: open a Honker watcher on the same file so we can later
        # wait_for_update instead of spinning (measures notify path when wired).
        hub = begin
          ::Honker::Database.new(path, watcher_poll_interval_ms: 5)
        rescue
          nil
        end

        File.write(reader_ready, "1")
        samples.times do |i|
          key = "inv-#{i}"
          # Wait until key appears (L2 visibility) — baseline coherence latency.
          # Always probe get first; only then wait on the Honker watcher so we
          # do not floor latency at poll_interval.
          t_wait0 = mono
          loop do
            val = cache.get(key)
            if val == "v#{i}"
              latencies_ms << (mono - t_wait0) * 1000.0
              break
            end
            if mono - t_wait0 > 2.0
              latencies_ms << (mono - t_wait0) * 1000.0
              break
            end
            if hub
              hub.wait_for_update(0.01)
            else
              sleep 0.0005
            end
          end
        end
        File.write(lat_file, JSON.generate(latencies_ms))
        hub&.close
        cache.close
        exit! 0
      end

      # Wait for reader
      deadline = mono + 5
      until File.exist?(reader_ready)
        raise "reader failed to start" if mono > deadline
        sleep 0.01
      end

      writer = build_cache(path)
      samples.times do |i|
        # Brief pause so reader is waiting
        sleep 0.002
        writer.set("inv-#{i}", "v#{i}")
        # If/when transactional notify exists, it would fire inside set.
      end
      writer.close

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
          kind: "l2_visibility", # becomes "l1_drop" when L1+honker ships
          samples: sorted.size,
          p50_ms: percentile(sorted, 50),
          p99_ms: percentile(sorted, 99),
          max_ms: sorted.last,
          mean_ms: sorted.sum / sorted.size
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
      report = run_baseline
      print_report(report)
      path = save_report(report)
      puts "Wrote #{path}"
    when "compare"
      unless File.file?(out_path)
        warn "No baseline at #{out_path}; run: #{$PROGRAM_NAME} baseline"
        exit 1
      end
      baseline = load_report
      current = run_baseline
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
      base = run_baseline
      print_report(base)
      save_report(base)
      puts "Wrote #{out_path}"
      inv = run_invalidate
      unless inv[:skipped] || inv["skipped"]
        print_report(inv)
        save_report(inv, File.expand_path("results/litecache_invalidate.json", __dir__))
      end
    when "help", "-h", "--help"
      puts <<~HELP
        Usage: #{$PROGRAM_NAME} [baseline|compare|invalidate|all]

        baseline   Measure current Litecache IPS; write JSON baseline
        compare    Re-measure and exit 2 if IPS < LITESTACK_BENCH_REGRESSION of baseline
        invalidate Cross-process visibility / future L1 invalidate latency
        all        baseline + invalidate
      HELP
    else
      warn "Unknown mode #{mode.inspect}"
      exit 1
    end
  end
end

LitecacheL1Bench.main(ARGV) if $PROGRAM_NAME == __FILE__
