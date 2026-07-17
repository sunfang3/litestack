# frozen_string_literal: true

# Coverage for GitHub issue #118:
# Litejob should not start background workers in the Rails console by default.
# https://github.com/oldmoe/litestack/issues/118

require_relative "helper"

class TestLitejobConsoleWorkers < Minitest::Test
  def setup
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    @prev_env = ENV["LITEJOB_WORKERS"]
    ENV.delete("LITEJOB_WORKERS")
  end

  def teardown
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    if @prev_env.nil?
      ENV.delete("LITEJOB_WORKERS")
    else
      ENV["LITEJOB_WORKERS"] = @prev_env
    end
    # Clear any console stub
    if defined?(Rails) && Rails.const_defined?(:Console, false)
      Rails.send(:remove_const, :Console) rescue nil
    end
  end

  def with_tmp_queue(**opts)
    path, dir = tmp_sqlite_path("console-jobq")
    q = nil
    begin
      # Bypass singleton for isolation
      Litejobqueue.reset_singleton!
      q = Litejobqueue.allocate
      q.send(:initialize, {path: path, logger: nil, sleep_intervals: [0.05], queues: [["default", 1]]}.merge(opts))
      yield q
    ensure
      q&.stop rescue nil
      Litejobqueue.reset_singleton!
      FileUtils.rm_rf(dir) if dir
    end
  end

  def test_rails_console_context_detection
    refute Litejobqueue.rails_console_context? unless defined?(Rails::Console)
    # Simulate rails console constant
    Object.const_set(:Rails, Module.new) unless defined?(Rails)
    Rails.const_set(:Console, Module.new) unless Rails.const_defined?(:Console)
    assert Litejobqueue.rails_console_context?
  ensure
    Rails.send(:remove_const, :Console) if defined?(Rails) && Rails.const_defined?(:Console, false)
  end

  def handle_count(q)
    Array(q.instance_variable_get(:@worker_handles)).size
  end

  # workers + optional GC background task when workers > 0
  def expected_handles(workers)
    w = workers.to_i
    (w > 0) ? w + 1 : 0
  end

  def test_console_defaults_to_zero_workers
    Object.const_set(:Rails, Module.new) unless defined?(Rails)
    Rails.const_set(:Console, Module.new) unless Rails.const_defined?(:Console)

    with_tmp_queue do |q|
      assert_equal 0, q.options[:workers]
      assert_equal 0, handle_count(q), "console must not spawn worker/GC threads by default"
      assert_nil q.instance_variable_get(:@gc)
    end
  ensure
    Rails.send(:remove_const, :Console) if defined?(Rails) && Rails.const_defined?(:Console, false)
  end

  def test_explicit_workers_option_overrides_console_default
    Object.const_set(:Rails, Module.new) unless defined?(Rails)
    Rails.const_set(:Console, Module.new) unless Rails.const_defined?(:Console)

    with_tmp_queue(workers: 2) do |q|
      assert_equal 2, q.options[:workers]
      assert_equal expected_handles(2), handle_count(q)
    end
  ensure
    Rails.send(:remove_const, :Console) if defined?(Rails) && Rails.const_defined?(:Console, false)
  end

  def test_env_litejob_workers_overrides_console_default
    Object.const_set(:Rails, Module.new) unless defined?(Rails)
    Rails.const_set(:Console, Module.new) unless Rails.const_defined?(:Console)
    ENV["LITEJOB_WORKERS"] = "1"

    with_tmp_queue do |q|
      assert_equal 1, q.options[:workers]
      assert_equal expected_handles(1), handle_count(q)
    end
  ensure
    Rails.send(:remove_const, :Console) if defined?(Rails) && Rails.const_defined?(:Console, false)
  end

  def test_non_console_keeps_default_workers
    # Ensure Console is not defined
    if defined?(Rails) && Rails.const_defined?(:Console, false)
      Rails.send(:remove_const, :Console)
    end

    with_tmp_queue do |q|
      # DEFAULT_OPTIONS workers is 5 when not in console and not overridden
      assert_equal 5, q.options[:workers]
      assert_equal expected_handles(5), handle_count(q)
    end
  end

  def test_console_still_accepts_enqueue
    Object.const_set(:Rails, Module.new) unless defined?(Rails)
    Rails.const_set(:Console, Module.new) unless Rails.const_defined?(:Console)

    with_tmp_queue do |q|
      id, queue = q.push("ConsoleJob", ["x"], 0, "default")
      refute_nil id
      assert_equal "default", queue
      assert_operator q.count, :>=, 1
    end
  ensure
    Rails.send(:remove_const, :Console) if defined?(Rails) && Rails.const_defined?(:Console, false)
  end
end
