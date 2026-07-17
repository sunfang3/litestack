# frozen_string_literal: true

require "sqlite3"
require "logger"
require "oj"
require "yaml"
require "pathname" # standard:disable Lint/RedundantRequireStatement
require "fileutils"
require "erb"
require "base64" # standard:disable Lint/RedundantRequireStatement
require "bigdecimal" # standard:disable Lint/RedundantRequireStatement

require_relative "litescheduler"
require_relative "schema_migrator"
require_relative "liteconnection"

module Litesupport
  class Error < StandardError; end

  # Detect the Rack or Rails environment.
  def self.detect_environment
    if defined?(Rails) && Rails.respond_to?(:env)
      Rails.env
    elsif ENV["RACK_ENV"]
      ENV["RACK_ENV"]
    elsif ENV["APP_ENV"]
      ENV["APP_ENV"]
    else
      "development"
    end
  end

  def self.environment
    @environment ||= detect_environment
  end

  # Databases will be stored by default at this path.
  def self.root(env = Litesupport.environment)
    ensure_root_volume detect_root(env)
  end

  # Default path where we'll store all of the databases.
  def self.detect_root(env)
    path = if ENV["LITESTACK_DATA_PATH"]
      ENV["LITESTACK_DATA_PATH"]
    elsif defined? Rails
      "./db"
    else
      "."
    end

    Pathname.new(path).join(env)
  end

  def self.ensure_root_volume(path)
    FileUtils.mkdir_p path unless path.exist?
    path
  end

  class Pool
    def initialize(count, &block)
      @count = count
      @block = block
      @resources = Thread::Queue.new
      @mutex = Thread::Mutex.new
      @closed = false
      @in_flight = 0
      @all = []
      @count.times do
        resource = @mutex.synchronize { block.call }
        @all << resource
        @resources << resource
      end
    end

    def closed?
      @closed
    end

    def size
      @count
    end

    # Drain every pooled resource (including in-flight after lease return) and close them.
    def close
      return if @closed
      @closed = true
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
      # Wait briefly for in-flight acquires to finish
      while @in_flight > 0 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.01
      end
      closed_ids = {}
      loop do
        begin
          resource = @resources.pop(true)
        rescue ThreadError
          break
        end
        next if closed_ids[resource.object_id]
        close_resource(resource)
        closed_ids[resource.object_id] = true
      end
      # Close any tracked resources not returned to the queue
      @all.each do |resource|
        next if closed_ids[resource.object_id]
        close_resource(resource)
        closed_ids[resource.object_id] = true
      end
    end

    def acquire
      raise Litestack::ClosedError, "connection pool is closed" if @closed
      result = nil
      resource = @resources.pop
      @mutex.synchronize { @in_flight += 1 }
      begin
        raise Litestack::ClosedError, "connection pool is closed" if @closed
        result = yield resource
      ensure
        @mutex.synchronize { @in_flight -= 1 }
        @resources << resource unless @closed
      end
      result
    end

    private

    def close_resource(resource)
      return unless resource
      if resource.respond_to?(:stmts) && resource.stmts
        resource.stmts.each_value do |stmt|
          stmt.close if stmt && !(stmt.respond_to?(:closed?) && stmt.closed?)
        rescue
          nil
        end
        resource.stmts.clear if resource.stmts.respond_to?(:clear)
      end
      resource.close if resource.respond_to?(:close) && !(resource.respond_to?(:closed?) && resource.closed?)
    rescue
      nil
    end
  end
end
