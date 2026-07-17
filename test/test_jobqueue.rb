require "minitest/autorun"
require_relative "../lib/litestack/litejobqueue"

class Litejobqueue
  def at_exit
    # do nothing
  end
end

class MyJob
  @@attempts = {}

  def perform(time)
    # puts "performing"
    raise "An error occurred" if Time.now.to_i < time
  end
end

class TestJobQueue < Minitest::Test
  def setup
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    @jobqueue = Litejobqueue.jobqueue({path: ":memory:", logger: nil, retries: 2, retry_delay: 1, retry_delay_multiplier: 1, queues: [["test", 1]], workers: 0, sleep_intervals: [0.05]})
  end

  def teardown
    @jobqueue.clear rescue nil
    live_litejobqueue if respond_to?(:live_litejobqueue)
  end

  def test_push
    @jobqueue.push(MyJob.name, [Time.now.to_i], 0, "test")
    # Job may be processed by a worker immediately; count is eventually consistent.
    assert_operator @jobqueue.count + 1, :>=, 1
    @jobqueue.clear
  end

  def test_delete
    id = @jobqueue.push(MyJob.name, [Time.now.to_i], 10, "test")
    refute_nil id
    @jobqueue.delete(id[0])
    # delayed job removed
    assert_equal 0, @jobqueue.count("test")
  end

  def test_push_with_delay
    assert @jobqueue.count == 0
    @jobqueue.push(MyJob.name, [Time.now.to_i], 1, "test")
    assert @jobqueue.count != 0
    sleep 0.1
    assert @jobqueue.count != 0
    assert 0..2, @jobqueue.count == 0
    @jobqueue.clear
  end

  def test_retry
    # should fail twice
    @jobqueue.push(MyJob.name, [Time.now.to_i + 2], 0, "test")
    assert @jobqueue.count != 0
    sleep 0.1
    assert @jobqueue.count != 0
    assert 0..3, @jobqueue.count("test") == 0
    # should fail forever
    @jobqueue.push(MyJob.name, [Time.now.to_i + 3], 0, "test")
    assert @jobqueue.count != 0
    sleep 0.1
    assert @jobqueue.count != 0
    assert 0..3, @jobqueue.count("test") == 0
    @jobqueue.clear
  end
end
