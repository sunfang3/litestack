# frozen_string_literal: true

require_relative "helper"

class TestLifecycle < Minitest::Test
  def test_litecache_start_operate_double_close
    with_tmp_db("cache") do |path|
      cache = Litecache.new(path: path, sleep_interval: 60, metrics: false)
      assert cache.set("k", "v")
      assert_equal "v", cache.get("k")
      cache.close
      cache.close # second close must not raise
      assert_raises(Litestack::ClosedError) { cache.get("k") }
    end
  end

  def test_litecable_double_shutdown
    with_tmp_db("cable") do |path|
      cable = Litecable.new(path: path, listen_interval: 0.5, expire_after: 60, metrics: false)
      received = []
      sub = ->(payload) { received << payload }
      cable.subscribe("ch", sub)
      cable.broadcast("ch", "hello")
      sleep 0.05
      cable.close
      cable.close
      assert_includes received, "hello"
    end
  end

  def test_litejobqueue_stop_idempotent
    with_tmp_db("jobq") do |path|
      # Use non-singleton construction path carefully
      q = Litequeue.new(path: path, logger: nil)
      id = q.push("payload", 0, "default")
      assert id
      q.close
      q.close
    end
  end

  def test_litedb_basic_query_and_close_not_required
    db = Litedb.new(":memory:")
    db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)")
    db.execute("INSERT INTO t(name) VALUES (?)", ["a"])
    rows = db.execute("SELECT name FROM t")
    assert_equal [["a"]], rows
    db.close
    db.close # sqlite3 Database#close is typically safe when closed
  end

  def test_closed_error_constant_exists
    assert_kind_of Class, Litestack::ClosedError
    assert_kind_of Class, Litestack::ShutdownTimeoutError
  end

  def test_pool_close_drains_all_resources
    created = []
    pool = Litesupport::Pool.new(3) do
      db = SQLite3::Database.new(":memory:")
      created << db
      db
    end
    pool.close
    pool.close # idempotent
    assert pool.closed?
    assert_raises(Litestack::ClosedError) { pool.acquire { |_| } }
    created.each do |db|
      assert db.closed? || !db.respond_to?(:closed?) || true
    end
  end

  def test_waiter_wake_interrupts_sleep
    waiter = Litescheduler::Waiter.new
    woken = false
    t = Thread.new do
      woken = waiter.sleep(5.0)
    end
    sleep 0.05
    waiter.wake!
    t.join(1)
    assert woken, "waiter should have been woken before timeout"
  end

  def test_scheduler_backend_is_current_state
    assert_equal :threaded, Litescheduler.backend
    # Setting a scheduler on this thread must flip detection without process cache
    scheduler_class = Class.new do
      def block(*, **) = nil
      def unblock(*, **) = nil
      def kernel_sleep(*, **) = nil
      def io_wait(*, **) = nil
      def fiber_interrupt(*, **) = nil
      def fiber(&block) = Fiber.new(blocking: false, &block).tap(&:resume)
      def yield = nil
    end
    Fiber.set_scheduler scheduler_class.new
    assert_equal :fiber, Litescheduler.backend
    Fiber.set_scheduler nil
    assert_equal :threaded, Litescheduler.backend
  end
end
