# frozen_string_literal: true

require_relative "helper"
require "stringio"
require "tmpdir"
require "fileutils"

describe "Litestack::HonkerStatus" do
  it "reports gem load and path watchability" do
    report = Litestack::HonkerStatus.check(live: false)
    assert report.key?(:gem)
    assert report.key?(:path)
    assert report.key?(:path_watchable)
    assert_equal false, report[:strict]
  end

  it "rejects :memory: as unwatchable" do
    report = Litestack::HonkerStatus.check(path: ":memory:", live: false)
    refute report[:path_watchable]
    refute report[:ok]
  end

  it "formats a human-readable report" do
    report = Litestack::HonkerStatus.check(live: false)
    text = Litestack::HonkerStatus.format(report)
    assert_match(/Honker status/, text)
    assert_match(/gem:/, text)
    assert_match(/path_watchable:/, text)
  end

  it "live-probes components when honker is available" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.load_honker_gem!

    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Dir.mktmpdir("honker-status-") do |dir|
      path = File.join(dir, "probe.sqlite3")
      FileUtils.touch(path)
      report = Litestack::HonkerStatus.check(path: path, live: true, strict: true)
      assert report[:gem], "gem should load"
      assert report[:path_watchable]
      comps = report[:components]
      assert comps["litejob.wakeup"][:active], comps["litejob.wakeup"].inspect
      assert comps["litejob.backend"][:active], comps["litejob.backend"].inspect
      assert comps["litecache.invalidate"][:active], comps["litecache.invalidate"].inspect
      assert comps["litecable.transport"][:active], comps["litecable.transport"].inspect
      assert report[:ok], report.inspect
    end
  ensure
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
  end

  it "run_cli! returns 0 when gem loads (non-strict)" do
    skip "honker gem not available" unless Litestack::Wakeup::Honker.load_honker_gem!

    io = StringIO.new
    Dir.mktmpdir("honker-status-cli-") do |dir|
      path = File.join(dir, "probe.sqlite3")
      FileUtils.touch(path)
      code = Litestack::HonkerStatus.run_cli!(path: path, strict: false, io: io)
      assert_equal 0, code
      assert_match(/Honker status OK/, io.string)
    end
  end

  it "run_cli! returns 1 in strict mode for memory path" do
    io = StringIO.new
    code = Litestack::HonkerStatus.run_cli!(path: ":memory:", strict: true, io: io)
    assert_equal 1, code
    assert_match(/NOT OK/, io.string)
  end
end
