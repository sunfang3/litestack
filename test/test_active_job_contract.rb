# frozen_string_literal: true

require_relative "helper"
require "active_job"
require "active_job/queue_adapters/litejob_adapter"

class TestActiveJobContract < Minitest::Test
  class SampleJob < ActiveJob::Base
    self.queue_adapter = :litejob
    cattr_accessor :performed
    def perform(msg)
      self.class.performed = msg
    end
  end

  def setup
    SampleJob.performed = nil
    live_litejobqueue
  end

  def teardown
    live_litejobqueue
  end

  def test_adapter_is_abstract_subclass
    adapter = ActiveJob::QueueAdapters::LitejobAdapter.new
    assert adapter.is_a?(ActiveJob::QueueAdapters::AbstractAdapter)
  end

  def test_enqueue_after_transaction_commit_hook
    adapter = ActiveJob::QueueAdapters::LitejobAdapter.new
    assert [true, false].include?(adapter.enqueue_after_transaction_commit?)
  end

  def test_stopping_predicate
    adapter = ActiveJob::QueueAdapters::LitejobAdapter.new
    assert_respond_to adapter, :stopping?
  end

  def test_enqueue_returns_provider_id
    adapter = ActiveJob::QueueAdapters::LitejobAdapter.new
    job = SampleJob.new("hi")
    job.queue_name = "default"
    id = adapter.enqueue(job)
    refute_nil id
  end
end
