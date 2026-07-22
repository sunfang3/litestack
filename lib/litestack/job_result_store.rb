# frozen_string_literal: true

require "oj"

module Litestack
  # Persist job outcomes so waiters can block until completion.
  # Uses a small table on the queue database (works for string and integer ids).
  class JobResultStore
    TABLE_SQL = <<~SQL
      CREATE TABLE IF NOT EXISTS _litestack_job_results(
        job_id TEXT PRIMARY KEY NOT NULL,
        status TEXT NOT NULL,
        value TEXT,
        error TEXT,
        created_at REAL NOT NULL DEFAULT (unixepoch('subsec')),
        expires_at REAL
      ) WITHOUT ROWID;
    SQL

    def initialize(jobqueue, options = {})
      @jobqueue = jobqueue
      @options = options
      @ttl_s = (options[:result_ttl] || options[:result_ttl_s] || 3600).to_i
      @ttl_s = 3600 if @ttl_s <= 0
      @enabled = false
      setup!
    end

    def enabled?
      @enabled
    end

    def save(job_id, status:, value: nil, error: nil)
      return false unless @enabled

      @jobqueue.send(:run_sql,
        "INSERT OR REPLACE INTO _litestack_job_results(job_id, status, value, error, expires_at) " \
        "VALUES (?, ?, ?, ?, unixepoch('subsec') + ?)",
        job_id.to_s,
        status.to_s,
        value.nil? ? nil : Oj.dump(value, mode: :strict),
        error&.to_s,
        @ttl_s)
      true
    rescue => e
      @jobqueue.instance_variable_get(:@logger)&.warn { "[litejob] result save failed: #{e.message}" }
      false
    end

    def get(job_id)
      return nil unless @enabled

      row = @jobqueue.send(:run_sql,
        "SELECT status, value, error FROM _litestack_job_results " \
        "WHERE job_id = ? AND (expires_at IS NULL OR expires_at > unixepoch('subsec'))",
        job_id.to_s)
      return nil if row.nil? || row.empty?

      status, value, error = row[0]
      {
        status: status,
        value: value.nil? ? nil : parse_jsonish(value),
        error: error
      }
    rescue
      nil
    end

    def sweep!
      return 0 unless @enabled

      @jobqueue.send(:run_sql,
        "DELETE FROM _litestack_job_results WHERE expires_at IS NOT NULL AND expires_at <= unixepoch('subsec')")
      0
    rescue
      0
    end

    def close
      # table lives on the jobqueue connection; nothing to close
    end

    private

    def setup!
      return if @options[:job_results] == false

      @jobqueue.send(:run_sql, TABLE_SQL)
      @enabled = true
    rescue => e
      @enabled = false
      @jobqueue.instance_variable_get(:@logger)&.warn { "[litejob] job results disabled: #{e.message}" }
    end

    def parse_jsonish(raw)
      Oj.load(raw)
    rescue
      raw
    end
  end
end
