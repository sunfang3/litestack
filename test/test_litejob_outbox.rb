# frozen_string_literal: true

require_relative "helper"
require "active_record"
require "active_job"
require "active_job/queue_adapters/litejob_adapter"

describe "LiteJob transactional outbox (database: primary)" do
  before do
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    Performance.reset!
    @dir = Dir.mktmpdir("litestack-outbox-")
    @path = File.join(@dir, "app.sqlite3")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: @path)
    ActiveRecord::Base.connection.create_table(:orders, force: true) do |t|
      t.string :name
    end
  end

  after do
    begin
      q = Litejobqueue.class_variable_get(:@@queue) rescue nil
      q&.stop rescue nil
    rescue
      nil
    end
    Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
    begin
      ActiveRecord::Base.remove_connection
    rescue
      nil
    end
    FileUtils.rm_rf(@dir) if @dir
    Performance.reset!
  end

  def build_queue(**opts)
    Litejobqueue.reset_singleton!
    Litejobqueue.jobqueue({
      path: @path, # overridden by database: primary when AR is up
      database: :primary,
      logger: nil,
      workers: 0,
      queues: [["default", 1]],
      retries: 1,
      outbox: true,
      leadership: false,
      lifecycle_stream: false
    }.merge(opts))
  end

  it "resolves path to the ActiveRecord primary database file" do
    q = build_queue
    assert_equal File.expand_path(@path), File.expand_path(q.options[:path].to_s)
    assert_equal true, q.options[:outbox]
    assert_equal false, q.options[:enqueue_after_transaction_commit]
  end

  it "creates the prefixed queue table on the primary database file" do
    q = build_queue
    tables = ActiveRecord::Base.connection.tables
    assert_equal "litestack_queue", q.queue_table
    assert_includes tables, "litestack_queue"
    refute_includes tables, "queue" # avoid bare name collision with apps
    assert_equal 0, q.count
  end

  it "rolls back the job when the AR transaction rolls back" do
    q = build_queue
    assert_equal 0, q.count
    t = q.queue_table

    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("INSERT INTO orders(name) VALUES ('a')")
      q.push("NoOpJob", [], 0, "default")
      # Outbox wrote on the AR raw connection — visible here, not necessarily
      # on LiteJob's separate pool connection until commit.
      ar_count = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{t}")
      assert_equal 1, ar_count.to_i
      raise ActiveRecord::Rollback
    end

    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM orders").to_i
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{t}").to_i
    assert_equal 0, q.count
  end

  it "commits the job with the business row in one transaction" do
    q = build_queue
    t = q.queue_table

    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("INSERT INTO orders(name) VALUES ('b')")
      q.push("NoOpJob", [], 0, "default")
    end

    assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM orders").to_i
    assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{t}").to_i
    assert_equal 1, q.count
  end

  it "allows an app table named queue alongside litestack_queue" do
    ActiveRecord::Base.connection.create_table(:queue, force: true) do |t|
      t.string :label
    end
    ActiveRecord::Base.connection.execute("INSERT INTO queue(label) VALUES ('app')")
    q = build_queue
    q.push("NoOpJob", [], 0, "default")
    assert_equal 1, q.count
    assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM queue").to_i
    assert_equal "app", ActiveRecord::Base.connection.select_value("SELECT label FROM queue LIMIT 1")
  end

  it "honors explicit empty table_prefix on primary" do
    q = build_queue(table_prefix: "")
    assert_equal "queue", q.queue_table
    assert_includes ActiveRecord::Base.connection.tables, "queue"
  end

  it "falls back to the LiteJob pool outside a transaction" do
    q = build_queue
    q.push("NoOpJob", [], 0, "default")
    assert_equal 1, q.count
  end

  it "disables enqueue_after_transaction_commit on the ActiveJob adapter" do
    build_queue
    adapter = ActiveJob::QueueAdapters::LitejobAdapter.new
    # Adapter uses Job which has its own singleton — re-point by ensuring jobqueue
    ActiveJob::QueueAdapters::LitejobAdapter::Job.instance_variable_set(:@options, nil)
    # Force Job to use our queue options via get_jobqueue already created
    refute adapter.enqueue_after_transaction_commit?
  end
end
