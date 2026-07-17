# frozen_string_literal: true

# Coverage must start before project code loads.
require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/test/"
  add_filter "/bench/"
  add_filter "/scripts/"
  add_filter "/gemfiles/"
  add_filter "/vendor/"
  # Measured baseline from first clean full suite on Ruby 4.0.5 + Rails 8.1.3 (Q4).
  # Line ~86% / branch ~58%; floors apply to full suite only (skip on partial/target runs).
  unless ENV["COVERAGE_PARTIAL"] == "1" || ENV["LITESTACK_PARTIAL_TEST"] == "1"
    minimum_coverage line: 80, branch: 50
  end
  add_group "Core", "lib/litestack"
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "litestack"
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "securerandom"

# Process-wide job queue used by some existing tests; recreated if closed.
LITEJOBQUEUE_TEST_OPTIONS = {
  path: ":memory:",
  retries: 1,
  retry_delay: 1,
  retry_delay_multiplier: 1,
  queues: [["test", 1], ["default", 1]],
  logger: nil,
  workers: 1
}.freeze

def live_litejobqueue
  existing = Litejobqueue.class_variable_get(:@@queue) rescue nil
  needs_reset = existing.nil? ||
    (existing.respond_to?(:closed?) && existing.closed?) ||
    existing.instance_variable_get(:@lifecycle_state) == :closed ||
    existing.options[:retries] != LITEJOBQUEUE_TEST_OPTIONS[:retries] ||
    existing.options[:path].to_s != LITEJOBQUEUE_TEST_OPTIONS[:path].to_s
  if needs_reset && Litejobqueue.respond_to?(:reset_singleton!)
    # Avoid close hang: nil out singleton without full stop when already closed
    begin
      Litejobqueue.reset_singleton!
    rescue
      Litejobqueue.class_variable_set(:@@queue, nil)
    end
  end
  $litejobqueue = Litejobqueue.jobqueue(LITEJOBQUEUE_TEST_OPTIONS)
  $litejobqueue
end

$litejobqueue = live_litejobqueue

# Setup a class to allow us to track and test whether code has been performed
class Performance
  def self.reset!
    @performances = 0
    @processed_items = {}
  end

  def self.performed!
    @performances ||= 0
    @performances += 1
  end

  def self.processed!(item, scope: :default)
    @processed_items ||= {}
    @processed_items[scope] ||= []
    @processed_items[scope] << item
  end

  def self.processed_items(scope = :default)
    @processed_items[scope]
  end

  def self.performances
    @performances || 0
  end
end

def perform_enqueued_jobs
  q = live_litejobqueue
  yield # enqueue jobs

  until q.count.zero?
    id, serialized_job = q.pop
    next if id.nil?
    q.send(:process_job, "default", id, serialized_job, false)
  end
end

def perform_enqueued_job
  q = live_litejobqueue
  performed = false

  until performed
    id, serialized_job = q.pop
    next if id.nil?
    q.send(:process_job, "default", id, serialized_job, false)
    performed = true
  end
end

module LitestackTestHelpers
  def tmp_sqlite_path(name = "test")
    dir = Dir.mktmpdir("litestack-#{name}-")
    path = File.join(dir, "#{name}.sqlite3")
    [path, dir]
  end

  def with_tmp_db(name = "test")
    path, dir = tmp_sqlite_path(name)
    yield path
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

class Minitest::Test
  include LitestackTestHelpers
end
