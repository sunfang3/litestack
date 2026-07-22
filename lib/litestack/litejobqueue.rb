# frozen_stringe_literal: true

require_relative "litequeue"
require_relative "litemetric"
require_relative "wakeup"
require_relative "job_backend"

##
# Litejobqueue is a job queueing and processing system designed for Ruby applications. It is built on top of SQLite, which is an embedded relational database management system that is #lightweight and fast.
#
# One of the main benefits of Litejobqueue is that it is very low on resources, making it an ideal choice for applications that need to manage a large number of jobs without incurring #high resource costs. In addition, because it is built on SQLite, it is easy to use and does not require any additional configuration or setup.
#
# Litejobqueue also integrates well with various I/O frameworks like Async and Polyphony, making it a great choice for Ruby applications that use these frameworks. It provides a #simple and easy-to-use API for adding jobs to the queue and for processing them.
#
# Overall, LiteJobQueue is an excellent choice for Ruby applications that require a lightweight, embedded job queueing and processing system that is fast, efficient, and easy to use.
class Litejobqueue < Litequeue
  include Litemetric::Measurable

  # the default options for the job queue
  # can be overridden by passing new options in a hash
  # to Litejobqueue.new, it will also be then passed to the underlying Litequeue object
  #   config_path: "./litejob.yml" -> were to find the configuration file (if any)
  #   path: "./db/queue.db"
  #   mmap_size: 128 * 1024 * 1024 -> 128MB to be held in memory
  #   sync: 1 -> sync only when checkpointing
  #   queues: [["default", 1, "spawn"]] -> an array of queues to process
  #   workers: 1 -> number of job processing workers
  #   sleep_intervals: [0.001, 0.005, 0.025, 0.125, 0.625, 3.125] -> sleep intervals for workers
  #   wakeup: :polling | :honker | { adapter: :honker, poll_interval_ms: 5 }
  #   backend: :litequeue | :honker
  # queues will be processed according to priority, such that if the queues are as such
  #   queues: [["default", 1, "spawn"], ["urgent", 10]]
  # it means that roughly, if the queues are full, for each 10 urgent jobs, 1 default job will be processed
  # the priority value is mandatory. The optional "spawn" parameter tells the job workers to spawn a separate execution context (thread or fiber, based on environment) for each job.
  # This can be particularly useful for long running, IO bound jobs. It is not recommended though for threaded environments, as it can result in creating many threads that may consudme a lot of memory.
  DEFAULT_OPTIONS = {
    config_path: "./litejob.yml",
    path: -> { Litesupport.root.join("queue.sqlite3") },
    queues: [["default", 1]],
    workers: 5,
    retries: 5,
    retry_delay: 60,
    retry_delay_multiplier: 10,
    dead_job_retention: 10 * 24 * 3600,
    gc_sleep_interval: 7200,
    logger: "STDOUT",
    sleep_intervals: [0.001, 0.005, 0.025, 0.125, 0.625, 1.0, 2.0],
    metrics: false,
    # Wake layer: :polling (default) or :honker (optional gem, file-backed path)
    wakeup: :polling,
    watcher_poll_interval_ms: 5,
    fallback_interval: 5.0,
    # When using wakeup: :honker, optionally require enqueue notifications
    wakeup_filter_notifications: false,
    queue_notify: false,
    # Job storage: :litequeue (destructive pop) or :honker (claim/ack)
    backend: :litequeue,
    visibility_timeout: 300,
    heartbeat_interval: 60
  }

  @@queue = nil
  @@mutex = Litescheduler::Mutex.new

  attr_reader :running

  # a method that returns a single instance of the job queue
  # for use by Litejob. Recreates the singleton if it was stopped/closed.
  def self.jobqueue(options = {})
    @@mutex.synchronize do
      if @@queue.nil? || (@@queue.respond_to?(:closed?) && @@queue.closed?) || @@queue.instance_variable_get(:@lifecycle_state) == :closed
        @@queue = nil
        q = allocate
        q.send(:initialize, options)
        @@queue = q
      end
      @@queue
    end
  end

  def self.new(options = {})
    jobqueue(options)
  end

  # True when the process looks like an interactive Rails console.
  # Used to default workers to 0 so enqueue still works but background
  # threads/fibers are not started (issue #118). Override with LITEJOB_WORKERS.
  def self.rails_console_context?
    return false unless defined?(Rails)
    return true if defined?(Rails::Console)
    return true if ARGV[0].to_s == "console" || ARGV.include?("console")
    false
  end

  # create new queue instance (only once instance will be created in the process)
  #   jobqueue = Litejobqueue.new
  #
  def initialize(options = {})
    @queues = [] # a place holder to allow workers to process
    @explicit_workers = options.key?(:workers)
    # Enable transactional notify when filtered honker wakeup is requested
    options = options.dup
    if honker_notify_implied?(options)
      options[:queue_notify] = true unless options.key?(:queue_notify)
      options[:wakeup_filter_notifications] = true if options[:wakeup].to_s == "honker" || options.dig(:wakeup, :adapter).to_s == "honker"
    end
    super(options)

    # group and order queues according to their priority
    pgroups = {}
    @options[:queues].each do |q|
      pgroups[q[1]] = [] unless pgroups[q[1]]
      pgroups[q[1]] << [q[0], q[2] == "spawn"]
    end
    @queues = pgroups.keys.sort.reverse.collect { |p| [p, pgroups[p]] }
    collect_metrics if @options[:metrics]
  end

  def metrics_identifier
    "Litejob" # overrides default identifier
  end

  # push a job to the queue
  #   class EasyJob
  #      def perform(any, number, of_params)
  #         # do anything
  #      end
  #   end
  #   jobqueue = Litejobqueue.new
  #   jobqueue.push(EasyJob, params) # the job will be performed asynchronously
  def push(jobclass, params, delay = 0, queue = nil)
    payload = Oj.dump({klass: jobclass, params: params, retries: @options[:retries], queue: queue}, mode: :strict)
    res = @job_backend.push(payload, delay, queue)
    capture(:enqueue, queue)
    @logger.info("[litejob]:[ENQ] queue:#{res[1]} class:#{jobclass} job:#{res[0]}")
    @wakeup&.signal
    res
  end

  def repush(id, job, delay = 0, queue = nil)
    res = @job_backend.repush(id, Oj.dump(job, mode: :strict), delay, queue)
    capture(:enqueue, queue)
    @logger.info("[litejob]:[ENQ] queue:#{res[0]} class:#{job[:klass] || job["klass"]} job:#{id}")
    @wakeup&.signal
    res
  end

  # delete a job from the job queue
  #   class EasyJob
  #      def perform(any, number, of_params)
  #         # do anything
  #      end
  #   end
  #   jobqueue = Litejobqueue.new
  #   id = jobqueue.push(EasyJob, params, 10) # queue for processing in 10 seconds
  #   jobqueue.delete(id)
  def delete(id)
    job = @job_backend.delete(id)
    @logger.info("[litejob]:[DEL] job: #{job}")
    job = Oj.load(job[0], symbol_keys: true) if job
    job
  end

  # pop is still used by tests/helpers for destructive drain of litequeue backend
  def pop(queue = "default", limit = 1)
    if @job_backend.name == :honker
      claim = @job_backend.claim(queue, limit)
      return nil if claim.nil?
      # For test helpers that expect [id, serialized] and process_job themselves,
      # auto-ack after returning would be wrong; return id+payload and let caller ack
      # via process_job path. For bare pop API, ack immediately after claim so pop
      # stays destructive-compatible.
      if limit == 1 && claim.length >= 2
        id, serialized, honker_job = claim
        @job_backend.ack(claim)
        [id, serialized]
      else
        claim
      end
    else
      super
    end
  end

  # stop the queue object (does not delete the jobs in the queue)
  # specifically useful for testing
  def stop
    @running = false
    @stopping = true
    close
  end

  def stopping?
    !!@stopping || !@running
  end

  # Reset the process-wide singleton (tests / forked children only).
  def self.reset_singleton!
    @@mutex.synchronize do
      if @@queue
        begin
          @@queue.instance_variable_set(:@running, false)
          @@queue.instance_variable_set(:@stopping, true)
          @@queue.instance_variable_set(:@lifecycle_state, :closed)
          @@queue.instance_variable_set(:@exit_callback_disarmed, true)
          begin
            @@queue.instance_variable_get(:@wakeup)&.close
          rescue
            nil
          end
          begin
            @@queue.instance_variable_get(:@job_backend)&.close
          rescue
            nil
          end
        rescue
          nil
        end
      end
      @@queue = nil
    end
  end

  # --- Backend hooks used by JobBackend::Destructive ---
  def _backend_push(value, delay, queue)
    Litequeue.instance_method(:push).bind_call(self, value, delay, queue)
  end

  def _backend_repush(id, value, delay, queue)
    Litequeue.instance_method(:repush).bind_call(self, id, value, delay, queue)
  end

  def _backend_delete(id)
    Litequeue.instance_method(:delete).bind_call(self, id)
  end

  def _backend_pop(queue, limit)
    Litequeue.instance_method(:pop).bind_call(self, queue, limit)
  end

  private

  def honker_notify_implied?(options)
    wakeup = options[:wakeup]
    filter = options[:wakeup_filter_notifications]
    adapter = if wakeup.is_a?(Hash)
      wakeup[:adapter] || wakeup["adapter"]
    else
      wakeup
    end
    filter == true || (adapter.to_s == "honker" && filter != false && options[:queue_notify])
  end

  def prepare_search_options(opts)
    sql_opts = super
    sql_opts[:klass] = opts[:klass]
    sql_opts[:params] = opts[:params]
    sql_opts
  end

  def exit_callback
    @running = false # stop all workers
    @stopping = true
    if @jobs_in_flight.to_i > 0
      @logger&.info { "[litejob] exit with #{@jobs_in_flight} jobs in flight; draining" }
      index = 0
      while @jobs_in_flight > 0 && index < 30 # 3 seconds grace period for jobs to finish
        sleep 0.1
        index += 1
      end
    end
    close
  end

  def setup
    # Tear down previous process-local resources (esp. after fork)
    begin
      @wakeup&.close
    rescue
      nil
    end
    begin
      @job_backend&.close
    rescue
      nil
    end

    super
    @jobs_in_flight = 0
    @stopping = false
    apply_worker_count_policy!

    @job_backend = Litestack::JobBackend.build(self, @options)
    @job_backend.setup!

    # Auto-enable queue_notify when filtered honker wakeup is on
    if @options[:wakeup_filter_notifications] && @options[:wakeup].to_s != "polling"
      @options[:queue_notify] = true
    end

    @wakeup = Litestack::Wakeup.build(@options)
    track_waiter(@wakeup) if @wakeup.respond_to?(:wake!) || @wakeup.respond_to?(:signal)

    count = @options[:workers].to_i
    @workers = count.times.collect { track_worker(create_worker) }
    # Dead-job GC is a background worker too — skip it when no workers run
    # (e.g. Rails console default). Only for destructive litequeue backend.
    @gc = if count > 0 && @job_backend.name != :honker
      track_worker(create_garbage_collector)
    end
    @mutex = Litescheduler::Mutex.new # reinitialize a mutex in setup as the environment could change after forking
  end

  # Prefer LITEJOB_WORKERS env, then explicit options[:workers], then console-safe default.
  def apply_worker_count_policy!
    if ENV.key?("LITEJOB_WORKERS")
      @options[:workers] = Integer(ENV["LITEJOB_WORKERS"])
    elsif !@explicit_workers && self.class.rails_console_context?
      @options[:workers] = 0
    end
    @options[:workers] = 0 if @options[:workers].to_i.negative?
  end

  def job_started
    @mutex.synchronize { @jobs_in_flight += 1 }
  end

  def job_finished
    @mutex.synchronize { @jobs_in_flight -= 1 }
  end

  # optionally run a job in its own context
  def schedule(spawn = false, &block)
    if spawn
      Litescheduler.spawn(&block)
    else
      yield
    end
  end

  def configured_queue_names
    names = []
    @queues.each do |_priority, queues|
      queues.each { |queue, _spawn| names << queue }
    end
    names
  end

  def wait_timeout_for_idle
    # Prefer sleep_intervals max as a soft cap only when using pure polling
    # without deadline; always deadline-aware when possible.
    next_at = begin
      @job_backend.next_fire_at(configured_queue_names)
    rescue
      nil
    end
    fallback = @options[:fallback_interval].to_f
    fallback = 5.0 if fallback <= 0

    if next_at
      delay = next_at - Time.now.to_f
      delay = 0 if delay.negative?
      [delay, fallback].min
    else
      # When using classic sleep_intervals style, use max interval as fallback
      # so we don't sleep longer than historical behaviour on pure polling.
      intervals = Array(@options[:sleep_intervals]).map(&:to_f)
      legacy = intervals.max || fallback
      [legacy, fallback].min
    end
  end

  # create a worker according to environment
  def create_worker
    waiter = track_waiter
    Litescheduler.spawn do
      worker_sleep_index = 0
      while @running
        processed = 0
        @queues.each do |priority, queues| # iterate through the levels
          queues.each do |queue, spawns| # iterate through the queues in the level
            batched = 0

            while (batched < priority) && (payload = claim_job(queue, 1))
              capture(:dequeue, queue)
              processed += 1
              batched += 1

              id, serialized_job, handle = unpack_claim(payload)
              process_job(queue, id, serialized_job, spawns, handle)

              Litescheduler.switch # give other contexts a chance to run here
            end
          end
        end
        if processed == 0
          timeout = wait_timeout_for_idle
          # Prefer shared wakeup when present; fall back to per-worker Waiter
          # for the first few tight polls when using pure polling adapter.
          if @wakeup && @wakeup.adapter_name == :honker
            @wakeup.wait(timeout: timeout)
            worker_sleep_index = 0
          elsif @wakeup
            # polling wakeup: use escalating intervals for idle CPU friendliness
            interval = @options[:sleep_intervals][worker_sleep_index] || timeout
            @wakeup.wait(timeout: [interval, timeout].min)
            worker_sleep_index += 1 if worker_sleep_index < (@options[:sleep_intervals].length - 1)
          else
            waiter.sleep(@options[:sleep_intervals][worker_sleep_index])
            worker_sleep_index += 1 if worker_sleep_index < (@options[:sleep_intervals].length - 1)
          end
        else
          worker_sleep_index = 0 # reset the index
        end
      end
    end
  end

  def claim_job(queue, limit)
    @job_backend.claim(queue, limit)
  end

  def unpack_claim(payload)
    # Destructive: [id, serialized]
    # Honker: [id, serialized, job]
    if payload.is_a?(Array) && payload.length >= 3
      [payload[0], payload[1], payload]
    else
      [payload[0], payload[1], payload]
    end
  end

  # create a gc for dead jobs
  def create_garbage_collector
    waiter = track_waiter
    Litescheduler.spawn do
      while @running
        while (jobs = claim_job("_dead", 100))
          # ack/destructive pop already removed rows
          if jobs[0].is_a? Array
            @logger.info "[litejob]:[DEL] garbage collector deleted #{jobs.length} dead jobs"
          else
            @logger.info "[litejob]:[DEL] garbage collector deleted 1 dead job"
          end
        end
        if @wakeup
          @wakeup.wait(timeout: @options[:gc_sleep_interval])
        else
          waiter.sleep(@options[:gc_sleep_interval])
        end
      end
    end
  end

  def process_job(queue, id, serialized_job, spawns, handle = nil)
    job = Oj.load(serialized_job)
    @logger.info "[litejob]:[DEQ] queue:#{queue} class:#{job["klass"]} job:#{id}"
    klass = Object.const_get(job["klass"])
    schedule(spawns) do # run the job in a new context
      job_started # (Litesupport.current_context)
      begin
        measure(:perform, queue) { klass.new.perform(*job["params"]) }
        @logger.info "[litejob]:[END] queue:#{queue} class:#{job["klass"]} job:#{id}"
        @job_backend.ack(handle || [id, serialized_job])
      rescue Exception => e # standard:disable Lint/RescueException
        handle_job_failure(queue, id, job, e, handle, serialized_job)
      ensure
        job_finished # (Litesupport.current_context)
      end
    end
  rescue Exception => e # standard:disable Lint/RescueException
    # Error extracting job info or scheduling — retrying the blob is not useful.
    @logger.error "[litejob]:[ERR] failed to process job #{id}: #{e.class}: #{e.message}"
    begin
      @job_backend.ack(handle) if handle && @job_backend.name == :honker
    rescue
      nil
    end
  end

  def handle_job_failure(queue, id, job, error, handle, serialized_job)
    capture(:fail, queue)
    if job["retries"] == 0
      @logger.error "[litejob]:[ERR] queue:#{queue} class:#{job["klass"]} job:#{id} failed with #{error}:#{error.message}, retries exhausted, moved to _dead queue"
      @job_backend.ack(handle || [id, serialized_job]) if @job_backend.name == :honker
      repush(id, job, @options[:dead_job_retention], "_dead")
    else
      capture(:retry, queue)
      retry_delay = @options[:retry_delay_multiplier].pow(@options[:retries] - job["retries"]) * @options[:retry_delay]
      job["retries"] -= 1
      @logger.error "[litejob]:[ERR] queue:#{queue} class:#{job["klass"]} job:#{id} failed with #{error}:#{error.message}, retrying in #{retry_delay} seconds"
      @job_backend.retry(handle || [id, serialized_job], Oj.dump(job, mode: :strict), retry_delay, queue)
    end
  rescue Exception => e # standard:disable Lint/RescueException
    @logger.error "[litejob]:[ERR] queue:#{queue} job:#{id} failure handling raised #{e.class}: #{e.message}"
  end

  def close_connection_pool
    begin
      @wakeup&.close
    rescue
      nil
    end
    @wakeup = nil
    begin
      @job_backend&.close
    rescue
      nil
    end
    @job_backend = nil
    super
  end
end
