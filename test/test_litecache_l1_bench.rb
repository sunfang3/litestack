# frozen_string_literal: true

require_relative "helper"
require_relative "../bench/bench_litecache_l1"

# Keeps the L1 bench harness honest: runs a tiny baseline and ensures
# compare does not false-positive, so future L1 work cannot ship without
# a working regression gate.
describe "Litecache L1 bench harness" do
  it "measures baseline metrics with positive IPS" do
    old_iters = ENV["LITESTACK_BENCH_ITERS"]
    ENV["LITESTACK_BENCH_ITERS"] = "50"
    report = LitecacheL1Bench.run_baseline
    m = report[:metrics]
    assert m[:set_ips] > 0
    assert m[:get_ips] > 0
    assert m[:get_random_ips] > 0
    assert m[:delete_ips] > 0
    assert_equal false, report[:l1][:enabled]
  ensure
    if old_iters
      ENV["LITESTACK_BENCH_ITERS"] = old_iters
    else
      ENV.delete("LITESTACK_BENCH_ITERS")
    end
  end

  it "compare_reports flags large regressions" do
    baseline = {
      "metrics" => {
        "set_ips" => 10_000.0,
        "get_ips" => 20_000.0,
        "get_random_ips" => 18_000.0,
        "delete_ips" => 12_000.0
      }
    }
    current_ok = {
      "metrics" => {
        "set_ips" => 9_800.0,
        "get_ips" => 19_500.0,
        "get_random_ips" => 17_500.0,
        "delete_ips" => 11_800.0
      }
    }
    current_bad = {
      "metrics" => {
        "set_ips" => 1_000.0,
        "get_ips" => 20_000.0,
        "get_random_ips" => 18_000.0,
        "delete_ips" => 12_000.0
      }
    }
    assert_empty LitecacheL1Bench.compare_reports(baseline, current_ok, floor: 0.95)
    failures = LitecacheL1Bench.compare_reports(baseline, current_bad, floor: 0.95)
    refute_empty failures
    assert failures.any? { |f| f.include?("set_ips") }
  end
end
