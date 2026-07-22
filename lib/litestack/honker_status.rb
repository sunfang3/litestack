# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module Litestack
  # Probe whether the optional Honker peer is loadable and whether litestack
  # components actually activate Honker adapters (vs silent polling/TTL fallback).
  #
  #   report = Litestack::HonkerStatus.check
  #   puts Litestack::HonkerStatus.format(report)
  #   exit 1 if report[:ok] == false && ENV["LITESTACK_HONKER_STRICT"] == "1"
  #
  # Or: +bundle exec rake litestack:honker:status+
  module HonkerStatus
    module_function

    # @param path [String, nil] file-backed SQLite path to probe (created if missing)
    # @param strict [Boolean] when true, ok=false if gem missing or live adapters fallback
    # @param live [Boolean] open real LiteJob / LiteCache / LiteCable instances
    # @return [Hash] serializable status report
    def check(path: nil, strict: false, live: true)
      notes = []
      gem_ok = Litestack::Wakeup::Honker.load_honker_gem!
      version = (gem_ok && defined?(::Honker::VERSION)) ? ::Honker::VERSION.to_s : nil

      probe_path = resolve_probe_path(path)
      path_ok = Litestack::Wakeup::Honker.watchable_path?(probe_path)
      notes << "path not watchable (use a real file path, not :memory:)" unless path_ok

      components = {}
      if live && gem_ok && path_ok
        components = live_probe(probe_path, notes)
      elsif live && !gem_ok
        notes << "skipped live component probes (honker gem not loadable)"
        components = expected_inactive
      elsif live && !path_ok
        notes << "skipped live component probes (path not watchable)"
        components = expected_inactive
      end

      ok = gem_ok && path_ok
      if strict
        ok &&= components_active?(components) if live && gem_ok && path_ok
        ok = false unless gem_ok
      end

      {
        ok: ok,
        strict: strict,
        gem: gem_ok,
        version: version,
        path: probe_path,
        path_watchable: path_ok,
        components: components,
        notes: notes
      }
    end

    def format(report)
      lines = []
      status = report[:ok] ? "OK" : "NOT OK"
      status = "#{status} (strict)" if report[:strict]
      lines << "Honker status #{status}"
      gem_line = report[:gem] ? "loaded" : "MISSING"
      gem_line = "#{gem_line} (#{report[:version]})" if report[:version]
      lines << "  gem:            #{gem_line}"
      lines << "  path:           #{report[:path]}"
      lines << "  path_watchable: #{report[:path_watchable]}"
      if report[:components].is_a?(Hash) && !report[:components].empty?
        lines << "  components:"
        report[:components].each do |name, info|
          active = info[:active]
          detail = info[:detail]
          mark = active ? "active" : "inactive"
          lines << "    #{name}: #{mark} — #{detail}"
        end
      end
      Array(report[:notes]).each { |n| lines << "  note: #{n}" }
      lines << "  hint: set LITESTACK_HONKER_STRICT=1 to fail when gem/adapters inactive"
      lines.join("\n")
    end

    # Print report to +io+; exit status for CLI (0 ok, 1 strict failure, 2 soft warn-only ok).
    def run_cli!(path: nil, strict: ENV["LITESTACK_HONKER_STRICT"] == "1", io: $stdout)
      report = check(path: path || ENV["LITESTACK_HONKER_PATH"], strict: strict)
      io.puts format(report)
      if report[:ok]
        0
      elsif strict
        1
      else
        # Non-strict: gem missing is still exit 1 so scripts notice; fallback notes are 0 if gem ok
        report[:gem] ? 0 : 1
      end
    end

    def resolve_probe_path(path)
      # Explicit path (arg or dedicated ENV) is used as-is — even :memory: —
      # so callers can verify unwatchable configs fail closed.
      explicit = [path, ENV["LITESTACK_HONKER_PATH"]].compact.map(&:to_s).reject(&:empty?).first
      return explicit if explicit

      # Soft discovery: first watchable queue path from common ENV names.
      discovered = [
        ENV["LITEBOARD_QUEUE_PATH"],
        ENV["LITEJOB_PATH"],
        ENV["LITESTACK_QUEUE_PATH"]
      ].compact.map(&:to_s).reject(&:empty?)
        .find { |p| Litestack::Wakeup::Honker.watchable_path?(p) }
      return discovered if discovered

      # Ephemeral file under tmp so status works without app config.
      dir = Dir.mktmpdir("litestack-honker-status-")
      file = File.join(dir, "probe.sqlite3")
      FileUtils.touch(file)
      file
    end
    private_class_method :resolve_probe_path

    def expected_inactive
      {
        "litejob.wakeup" => {active: false, detail: "not probed"},
        "litejob.backend" => {active: false, detail: "not probed"},
        "litecache.invalidate" => {active: false, detail: "not probed"},
        "litecable.transport" => {active: false, detail: "not probed"}
      }
    end
    private_class_method :expected_inactive

    def components_active?(components)
      return false if components.nil? || components.empty?
      components.all? { |_k, v| v[:active] }
    end
    private_class_method :components_active?

    def live_probe(path, notes)
      out = {}

      # --- LiteJob: wakeup + backend ---
      q = nil
      begin
        # Process-wide singleton may already hold a :memory: queue from tests —
        # reset so we actually open the probe path with Honker options.
        Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
        q = Litejobqueue.jobqueue(
          path: path,
          backend: :honker,
          wakeup: :honker,
          workers: 0,
          queues: [["default", 1]],
          logger: nil,
          leadership: false,
          lifecycle_stream: false,
          job_results: false
        )
        wakeup = q.instance_variable_get(:@wakeup)
        backend = q.instance_variable_get(:@job_backend)
        w_name = wakeup.respond_to?(:adapter_name) ? wakeup.adapter_name : :unknown
        b_name = backend.class.name
        out["litejob.wakeup"] = {
          active: w_name.to_sym == :honker,
          detail: "adapter=#{w_name}"
        }
        out["litejob.backend"] = {
          active: b_name.end_with?("JobBackend::Honker"),
          detail: "class=#{b_name}"
        }
        notes << "litejob wakeup fell back to #{w_name}" unless out["litejob.wakeup"][:active]
        notes << "litejob backend is not Honker" unless out["litejob.backend"][:active]
      rescue => e
        out["litejob.wakeup"] = {active: false, detail: "#{e.class}: #{e.message}"}
        out["litejob.backend"] = {active: false, detail: "#{e.class}: #{e.message}"}
        notes << "litejob probe failed: #{e.class}: #{e.message}"
      ensure
        begin
          q&.stop
        rescue
          nil
        end
        Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
      end

      # --- LiteCache L1 + invalidate ---
      cache = nil
      begin
        cache_path = path.sub(/(\.sqlite3)?\z/, "-cache.sqlite3")
        FileUtils.touch(cache_path) unless File.exist?(cache_path)
        cache = Litecache.new(
          path: cache_path,
          logger: nil,
          sleep_interval: 3600,
          l1: true,
          invalidate: :honker,
          l1_ttl: 60
        )
        stats = cache.l1_stats
        active = !!stats[:honker] && stats[:invalidate_mode].to_s == "honker"
        out["litecache.invalidate"] = {
          active: active,
          detail: "l1=#{stats[:enabled]} invalidate=#{stats[:invalidate_mode]} honker=#{stats[:honker]}"
        }
        notes << "litecache invalidate not honker (#{stats[:invalidate_mode]})" unless active
      rescue => e
        out["litecache.invalidate"] = {active: false, detail: "#{e.class}: #{e.message}"}
        notes << "litecache probe failed: #{e.class}: #{e.message}"
      ensure
        begin
          cache&.close(timeout: 2)
        rescue
          nil
        end
      end

      # --- LiteCable transport ---
      cable = nil
      begin
        cable_path = path.sub(/(\.sqlite3)?\z/, "-cable.sqlite3")
        FileUtils.touch(cable_path) unless File.exist?(cable_path)
        cable = Litecable.new(
          path: cable_path,
          transport: :honker,
          logger: nil,
          metrics: false
        )
        opts = cable.instance_variable_get(:@options) || {}
        mode = (opts[:transport] || :unknown).to_sym
        # Active honker leaves @honker_db set; soft fallback rewrites transport to :polling.
        active = !cable.instance_variable_get(:@honker_db).nil? && mode == :honker
        out["litecable.transport"] = {
          active: active,
          detail: "transport=#{mode} honker_db=#{active}"
        }
        notes << "litecable transport not honker (#{mode})" unless active
      rescue => e
        out["litecable.transport"] = {active: false, detail: "#{e.class}: #{e.message}"}
        notes << "litecable probe failed: #{e.class}: #{e.message}"
      ensure
        begin
          cable&.close
        rescue
          nil
        end
      end

      out
    end
    private_class_method :live_probe
  end
end
