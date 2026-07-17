# frozen_string_literal: true

module Litescheduler
  # Detect scheduler from the *current* thread/state — never a process-global cache
  # that can go stale after Fiber.scheduler set/unset or after fork (Ruby clears
  # the scheduler in the child).
  def self.backend
    if Fiber.scheduler
      :fiber
    elsif defined?(Polyphony)
      :polyphony
    elsif defined?(Iodine)
      :iodine
    else
      :threaded
    end
  end

  # Kept for tests that clear state between cases.
  def self.reset_backend!
    # no-op: backend is no longer process-cached
  end

  # Spawn a new execution context; returns a waitable handle (Thread or FiberHandle).
  def self.spawn(&block)
    case backend
    when :fiber
      FiberHandle.new(Fiber.schedule(&block))
    when :polyphony
      FiberHandle.new(spin(&block))
    when :threaded, :iodine
      Thread.new(&block)
    end
  end

  def self.storage
    fiber_backed? ? Fiber.current.storage : Thread.current
  end

  def self.current
    fiber_backed? ? Fiber.current : Thread.current
  end

  def self.switch
    case backend
    when :fiber
      Fiber.scheduler.yield
      true
    when :polyphony
      Fiber.current.schedule
      Thread.current.switch_fiber
      true
    else
      false
    end
  end

  def self.fiber_backed?
    backend == :fiber || backend == :polyphony
  end

  private_class_method :fiber_backed?

  # Uniform wait/alive? surface for Thread and Fiber-backed workers.
  class FiberHandle
    def initialize(fiber)
      @fiber = fiber
    end

    def alive?
      @fiber.respond_to?(:alive?) ? @fiber.alive? : false
    end

    def join(_timeout = nil)
      # Fiber workers exit when their loop ends; nothing to join.
      nil
    end

    def kill
      # Best-effort: fibers cannot be forcibly killed like threads.
      nil
    end
  end

  class Mutex
    def initialize
      @mutex = Thread::Mutex.new
    end

    def synchronize(&block)
      # Always use a real mutex; Fiber scheduler hooks handle contention under fibers.
      @mutex.synchronize { block.call }
    end
  end

  # Interruptible sleeper: workers sleep until duration elapses or wake is signaled.
  class Waiter
    def initialize
      @mutex = Thread::Mutex.new
      @cv = Thread::ConditionVariable.new
      @woken = false
    end

    def sleep(duration)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration.to_f
      @mutex.synchronize do
        @woken = false
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0 || @woken
          @cv.wait(@mutex, remaining)
        end
        @woken
      end
    end

    def wake!
      @mutex.synchronize do
        @woken = true
        @cv.broadcast
      end
    end
  end

  module ForkListener
    def self.listeners
      @listeners ||= []
    end

    def self.listen(&block)
      token = block
      listeners << token
      token
    end

    def self.unlisten(token)
      listeners.delete(token)
    end

    def self.clear!
      @listeners = []
    end
  end

  module Forkable
    def _fork(*args)
      ppid = Process.pid
      result = super
      if Process.pid != ppid && [:threaded, :iodine].include?(Litescheduler.backend)
        # Ruby clears Fiber.scheduler after fork; do not close app-owned schedulers.
        ForkListener.listeners.each { |l| l.call }
      end
      result
    end
  end
end

Process.singleton_class.prepend(Litescheduler::Forkable) unless Process.singleton_class.ancestors.include?(Litescheduler::Forkable)
