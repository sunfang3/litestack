# frozen_string_literal: true

module Litesupport
  module Liteconnection
    include Litescheduler::Forkable

    DEFAULT_SHUTDOWN_TIMEOUT = 5.0

    # Lifecycle states: :initializing, :running, :closing, :shutdown_failed, :closed
    def lifecycle_state
      @lifecycle_state ||= :initializing
    end

    def options
      @options
    end

    def closed?
      lifecycle_state == :closed
    end

    def shutdown_failed?
      lifecycle_state == :shutdown_failed
    end

    # Close the component. Idempotent: repeated close does not raise once closed.
    # On worker timeout: enter :shutdown_failed without closing SQLite under live tasks;
    # a later close retries drain deterministically.
    def close(timeout: shutdown_timeout)
      return self if @lifecycle_state == :closed
      return self if @lifecycle_state == :closing && @closing_from_close

      @closing_from_close = true
      @lifecycle_state = :closing
      @running = false
      wake_workers!

      timed_out = false
      begin
        stop_workers(timeout: timeout)
      rescue Litestack::ShutdownTimeoutError
        timed_out = true
        @lifecycle_state = :shutdown_failed
        @logger&.warn { "[litestack] #{self.class.name} shutdown timed out; SQLite left open for retry" }
      rescue => e
        @logger&.warn { "[litestack] worker shutdown error: #{e.class}: #{e.message}" }
      end

      unless timed_out
        # Only close SQLite after no worker can touch it
        begin
          close_connection_pool
        rescue => e
          @logger&.warn { "[litestack] connection close error: #{e.class}: #{e.message}" }
        end
        @lifecycle_state = :closed
        @exit_callback_disarmed = true
      end
      raise Litestack::ShutdownTimeoutError, "#{self.class.name} shutdown timed out" if timed_out && !@in_exit_callback
      self
    ensure
      @closing_from_close = false
      @running = false
    end

    def size
      ensure_open!
      run_sql("SELECT size.page_size * count.page_count FROM pragma_page_size() AS size, pragma_page_count() AS count")[0][0].to_f / (1024 * 1024)
    end

    def journal_mode
      ensure_open!
      run_method(:journal_mode)
    end

    def synchronous
      ensure_open!
      run_method(:synchronous)
    end

    def path
      ensure_open!
      run_method(:filename)
    end

    def transaction(mode = :immediate)
      ensure_open!
      return yield @checked_out_conn if @checked_out_conn&.transaction_active?
      with_connection do |conn|
        if !conn.transaction_active?
          conn.transaction(mode) do
            yield conn
          end
        else
          yield conn
        end
      end
    end

    private

    def shutdown_timeout
      (@options && @options[:shutdown_timeout]) || DEFAULT_SHUTDOWN_TIMEOUT
    end

    def ensure_open!
      if @lifecycle_state == :closed || @lifecycle_state == :closing || @lifecycle_state == :shutdown_failed
        raise Litestack::ClosedError, "#{self.class.name} is #{@lifecycle_state}"
      end
    end

    def init(options = {})
      configure(options)
      setup
      @exit_callback_disarmed = false
      at_exit do
        exit_callback unless @exit_callback_disarmed
      end
      Litescheduler::ForkListener.listen do
        setup unless closed?
      end
    end

    def configure(options = {})
      defaults = begin
        self.class::DEFAULT_OPTIONS
      rescue
        {}
      end
      @options = defaults.merge(options)
      config = begin
        YAML.safe_load(ERB.new(File.read(@options[:config_path])).result)
      rescue
        {}
      end
      config = config[Litesupport.environment] if config[Litesupport.environment]
      if config.is_a?(Hash)
        config.keys.each do |k|
          config[k.to_sym] = config[k]
          config.delete k
        end
        @options.merge!(config)
      end
      @options.merge!(options)
    end

    def setup
      @conn = create_pooled_connection(@options[:connection_count])
      @logger = create_logger
      @running = true
      @lifecycle_state = :running
      @worker_handles = []
      @worker_waiters = []
      @exit_callback_disarmed = false
    end

    def create_logger
      @options[:logger] = nil unless @options[:logger]
      return @options[:logger] if @options[:logger].respond_to? :info
      return Logger.new($stdout) if @options[:logger] == "STDOUT"
      return Logger.new($stderr) if @options[:logger] == "STDERR"
      return Logger.new(@options[:logger]) if @options[:logger].is_a? String
      Logger.new(IO::NULL)
    end

    def exit_callback
      @in_exit_callback = true
      close
    rescue Litestack::ShutdownTimeoutError, Litestack::ClosedError
      # Process is exiting; leave shutdown_failed/closed without aborting exit.
      nil
    ensure
      @in_exit_callback = false
    end

    # Override in components that spawn background workers.
    # Should signal workers to stop and join with timeout.
    def stop_workers(timeout:)
      handles = Array(@worker_handles)
      return if handles.empty?

      wake_workers!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      still_alive = []
      handles.each do |handle|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          still_alive = handles.select { |h| handle_alive?(h) }
          break
        end
        join_worker_handle(handle, remaining)
        still_alive << handle if handle_alive?(handle)
      end
      if still_alive.any?
        @worker_handles = still_alive
        raise Litestack::ShutdownTimeoutError,
          "#{self.class.name} shutdown timed out (#{still_alive.size} live handle(s))"
      end
      @worker_handles = []
      @worker_waiters = []
    end

    def handle_alive?(handle)
      handle.respond_to?(:alive?) ? handle.alive? : false
    end

    def join_worker_handle(handle, remaining)
      if handle.respond_to?(:join)
        handle.join(remaining)
      end
    end

    def track_worker(handle)
      @worker_handles ||= []
      @worker_handles << handle if handle
      handle
    end

    def track_waiter(waiter = Litescheduler::Waiter.new)
      @worker_waiters ||= []
      @worker_waiters << waiter
      waiter
    end

    def wake_workers!
      Array(@worker_waiters).each { |w| w.wake! if w.respond_to?(:wake!) }
    end

    def close_connection_pool
      return unless @conn

      pool = @conn
      @conn = nil
      pool.acquire do |q|
        if q.respond_to?(:stmts) && q.stmts
          q.stmts.each_pair do |k, stmt|
            begin
              stmt.close unless stmt_closed?(stmt)
            rescue
              # already closed
            end
            q.stmts[k] = nil
          end
          q.stmts.clear if q.stmts.respond_to?(:clear)
        end
        begin
          q.close unless connection_closed?(q)
        rescue
          # already closed
        end
      end
    rescue ThreadError, Litestack::ClosedError
      # pool drained / already closed
    end

    def stmt_closed?(stmt)
      stmt.respond_to?(:closed?) && stmt.closed?
    end

    def connection_closed?(conn)
      conn.respond_to?(:closed?) && conn.closed?
    end

    def run_stmt(stmt, *args)
      ensure_open!
      acquire_connection { |conn| conn.stmts[stmt].execute!(*args) }
    end

    def run_sql(sql, *args)
      ensure_open!
      acquire_connection { |conn| conn.execute(sql, args) }
    end

    def run_method(method, *args)
      ensure_open!
      acquire_connection { |conn| conn.send(method, *args) }
    end

    def run_stmt_method(stmt, method, *args)
      ensure_open!
      acquire_connection { |conn| conn.stmts[stmt].send(method, *args) }
    end

    def acquire_connection
      if @checked_out_conn
        yield @checked_out_conn
      else
        raise Litestack::ClosedError, "#{self.class.name} has no connection pool" unless @conn
        @conn.acquire { |conn| yield conn }
      end
    end

    def with_connection
      raise Litestack::ClosedError, "#{self.class.name} has no connection pool" unless @conn
      @conn.acquire do |conn|
        @checked_out_conn = conn
        yield conn
      ensure
        @checked_out_conn = nil
      end
    end

    def create_pooled_connection(count = 1)
      count = 1 unless count&.is_a?(Integer)
      Litesupport::Pool.new(count) { create_connection }
    end

    def create_connection(path_to_sql_file = nil)
      conn = SQLite3::Database.new(@options[:path])
      conn.busy_handler { Litescheduler.switch || sleep(rand * 0.002) }
      conn.journal_mode = "WAL"
      conn.synchronous = @options[:sync] || 1
      conn.mmap_size = @options[:mmap_size] || 0
      conn.instance_variable_set(:@stmts, {})
      class << conn
        attr_reader :stmts
      end
      yield conn if block_given?

      unless path_to_sql_file.nil?
        sql = Litestack::SchemaMigrator.load_sql_yaml(path_to_sql_file)
        migrator = Litestack::SchemaMigrator.new(
          conn,
          path: @options[:path],
          sql_definition: sql,
          component: self.class.name,
          logger: @logger,
          destructive_versions: @options[:destructive_schema_versions]
        )
        # During connection setup we already hold the connection; for :memory: skip advisory locks.
        # Apply schema using the migrator's step logic when versions pending; for bootstrap keep simple path for empty/new DBs.
        apply_schema_with_migrator(conn, sql, migrator)
        prepare_statements(conn, sql)
      end
      conn
    end

    def apply_schema_with_migrator(conn, sql, migrator)
      schema = sql["schema"] || sql[:schema]
      return unless schema.is_a?(Hash)

      version = conn.get_first_value("PRAGMA user_version").to_i
      pending = schema.keys.map { |k| Integer(k) }.select { |v| v > version }.sort
      return if pending.empty?

      # For new/in-process connections, apply steps transactionally without advisory lock
      # when the DB is in-memory or freshly created empty file. File-backed upgrades with
      # existing data go through full migrator when path is real and has prior version.
      if version.positive? && file_path_for_migration?
        migrator.migrate!
      else
        pending.each do |v|
          statements = schema[v] || schema[v.to_s]
          conn.transaction do
            statements.each do |name, s|
              conn.execute(s)
            rescue SQLite3::SQLException => e
              # Historical fixtures may already contain schema objects with user_version 0.
              raise unless e.message.match?(/already exists/i)
            rescue => e
              warn "Error parsing #{name}"
              warn s
              raise e
            end
            conn.user_version = v
          end
        end
      end
    end

    def file_path_for_migration?
      path = @options[:path].to_s
      path != ":memory:" && !path.start_with?("file:") && File.file?(path)
    end

    def prepare_statements(conn, sql)
      stmts = sql["stmts"] || sql[:stmts] || {}
      stmts.each do |k, v|
        conn.stmts[k.to_sym] = conn.prepare(v)
      rescue => e
        warn "Error parsing #{k}"
        warn v
        raise e
      end
    end
  end
end
