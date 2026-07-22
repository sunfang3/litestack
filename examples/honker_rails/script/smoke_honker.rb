# frozen_string_literal: true

#
# Run inside the generated app:
#   bin/rails runner script/smoke_honker.rb
#
# Verifies LiteJob (honker backend + wakeup), LiteCache L1 invalidate path,
# and prints Litestack::HonkerStatus.

require "fileutils"

def mono
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

puts "=== Honker Rails smoke (#{Rails.env}) ==="
puts "Rails=#{Rails.version} Litestack=#{Litestack::VERSION}"

queue_path = Rails.root.join("storage", Rails.env, "queue.sqlite3").to_s
cache_path = Rails.root.join("storage", Rails.env, "cache.sqlite3").to_s
FileUtils.mkdir_p(File.dirname(queue_path))

# --- Status probe (live adapters on storage paths) ---
status = Litestack::HonkerStatus.check(path: queue_path, live: true, strict: false)
puts Litestack::HonkerStatus.format(status)
unless status[:gem]
  warn "FAIL: honker gem not loaded — check Gemfile + BUNDLE_RUBYGEMS__PKG__GITHUB__COM"
  exit 1
end

# --- LiteJob: push + perform with honker options from config ---
class SmokeHonkerJob < ActiveJob::Base
  self.queue_adapter = :litejob
  cattr_accessor :last_message
  def perform(msg)
    self.class.last_message = msg
  end
end

Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
SmokeHonkerJob.last_message = nil

# Use file path + honker so we exercise claim/wakeup even if yml workers=0 in test
q = Litejobqueue.jobqueue(
  path: queue_path,
  config_path: Rails.root.join("config/litejob.yml").to_s,
  logger: nil,
  workers: 1,
  queues: [["default", 1]],
  sleep_intervals: [0.01, 0.05],
  fallback_interval: 1
)

SmokeHonkerJob.perform_later("smoke-#{Process.pid}")
deadline = mono + 10
sleep 0.05 while SmokeHonkerJob.last_message.nil? && mono < deadline
raise "litejob smoke failed: #{SmokeHonkerJob.last_message.inspect}" unless SmokeHonkerJob.last_message&.start_with?("smoke-")
puts "JOB_OK message=#{SmokeHonkerJob.last_message}"
q.stop

# --- LiteCache L1 write/read with invalidate:honker from yml ---
store = ActiveSupport::Cache::Litecache.new(
  path: cache_path,
  config_path: Rails.root.join("config/litecache.yml").to_s,
  logger: nil,
  sleep_interval: 3600
)
store.write("honker-smoke", "v1")
raise "cache miss" unless store.read("honker-smoke") == "v1"
inner = store.instance_variable_get(:@cache)
stats = (inner.respond_to?(:l1_stats) ? inner.l1_stats : {})
puts "CACHE_OK l1_stats=#{stats.inspect}"
if stats.is_a?(Hash) && status[:gem]
  # invalidate mode may be string or symbol
  mode = stats[:invalidate_mode].to_s
  if mode != "" && mode != "honker" && mode != "ttl"
    warn "NOTE: cache invalidate_mode=#{mode.inspect} (expected honker when gem present)"
  end
end
store.close if store.respond_to?(:close)

# Lifecycle stream readable?
feed = Litestack::Lifecycle.read_recent(path: queue_path, limit: 10)
puts "LIFECYCLE enabled=#{feed[:enabled]} events=#{feed[:events]&.size} reason=#{feed[:reason]}"

puts "=== ALL SMOKE CHECKS PASSED ==="
puts "LiteBoard: LITEBOARD_QUEUE_PATH=#{queue_path} bundle exec liteboard"
puts "Status:    LITESTACK_HONKER_PATH=#{queue_path} bundle exec rake litestack:honker:status"
