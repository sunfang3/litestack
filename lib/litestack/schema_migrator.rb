# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "time"

module Litestack
  # Centralized forward schema upgrades for durable components.
  #
  # Backup topology (when destructive):
  #   A = migration connection (holds BEGIN IMMEDIATE write lock)
  #   B = independent read-only source for online backup
  #   C = exclusive-create destination partial file
  # Never use A as the backup source (would BUSY/LOCKED).
  class SchemaMigrator
    ADVISORY_LOCK_SUFFIX = ".litestack-migrate.lock"
    BACKUP_PREFIX = ".litestack-backup-v"
    DEFAULT_LOCK_TIMEOUT = 5.0
    DEFAULT_LOCK_POLL = 0.05
    BACKUP_STEP_RETRIES = 50
    FORBIDDEN_SQL = /\b(BEGIN|COMMIT|ROLLBACK|END|VACUUM|ATTACH|DETACH|PRAGMA\s+journal_mode)\b/i

    # sqlite3 backup step status codes (mirror C API)
    SQLITE_OK = 0
    SQLITE_BUSY = 5
    SQLITE_LOCKED = 6
    SQLITE_DONE = 101

    attr_reader :path, :sql_definition, :component, :logger, :events, :backup_path

    def initialize(conn, path:, sql_definition:, component: "unknown", logger: nil, destructive_versions: nil, lock_timeout: DEFAULT_LOCK_TIMEOUT)
      @conn = conn # connection A
      @path = path.to_s
      @sql_definition = sql_definition
      @component = component.to_s
      @logger = logger
      @lock_timeout = lock_timeout.to_f
      @destructive_versions = Array(destructive_versions).map(&:to_i)
      @events = []
      @backup_path = nil
      @advisory_io = nil
    end

    def migrate!
      schema = validate_schema!
      current = user_version
      pending = schema.select { |version, _| version > current }
      return {from: current, to: current, backup: nil, steps: []} if pending.empty?

      reject_forbidden_sql!(pending)
      emit("migration.start", source_version: current, target_version: pending.keys.max)
      preflight_source!

      with_advisory_lock do
        with_write_lock do
          destructive = pending.keys.any? { |v| destructive_version?(v) } ||
            pending.values.any? { |stmts| stmts.values.any? { |s| s.to_s.match?(/\bDROP\b|\bREBUILD\b/i) } }
          if destructive && file_backed?
            @backup_path = create_verified_backup!(current)
            emit("backup.created",
              source_version: current,
              backup: File.basename(@backup_path),
              checksum: @backup_checksum,
              size: @backup_size)
          end

          applied = []
          pending.each do |version, statements|
            apply_step!(version, statements)
            applied << version
            emit("step.completed", step: version, source_version: current, target_version: pending.keys.max)
          end

          verify_full!(@conn)
          final = user_version
          emit("migration.succeeded", source_version: current, target_version: final, backup: @backup_path && File.basename(@backup_path))
          {from: current, to: final, backup: @backup_path, steps: applied}
        end
      end
    rescue MigrationBusyError, InvalidMigrationError, BackupError
      raise
    rescue => e
      emit("migration.failed", error_class: e.class.name, message: e.message, backup: @backup_path && File.basename(@backup_path.to_s))
      raise MigrationError, "Migration failed for #{@component}: #{e.class}: #{e.message}"
    ensure
      release_advisory_lock
    end

    def with_destructive_protection!(label: "destructive")
      emit("migration.start", source_version: user_version, target_version: user_version, step: label)
      with_advisory_lock do
        under_write_lock do
          if file_backed?
            @backup_path = create_verified_backup!(user_version)
            emit("backup.created",
              source_version: user_version,
              backup: File.basename(@backup_path),
              checksum: @backup_checksum,
              size: @backup_size)
          end
          result = yield
          verify_full!(@conn)
          emit("migration.succeeded", source_version: user_version, target_version: user_version, step: label)
          result
        end
      end
    rescue MigrationBusyError, BackupError
      raise
    rescue => e
      emit("migration.failed", error_class: e.class.name, message: e.message, backup: @backup_path && File.basename(@backup_path.to_s))
      raise MigrationError, "Destructive change failed for #{@component}: #{e.class}: #{e.message}"
    ensure
      release_advisory_lock
    end

    def user_version
      @conn.get_first_value("PRAGMA user_version").to_i
    end

    def self.load_sql_yaml(path)
      YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    rescue => e
      raise InvalidMigrationError, "Invalid SQL YAML at #{File.basename(path)}: #{e.message}"
    end

    def self.validate_definition!(sql)
      raise InvalidMigrationError, "SQL definition must be a Hash" unless sql.is_a?(Hash)
      schema = sql["schema"] || sql[:schema]
      raise InvalidMigrationError, "SQL definition missing 'schema'" unless schema.is_a?(Hash)
      versions = schema.keys.map { |k| Integer(k) }.sort
      versions.each_cons(2) do |a, b|
        raise InvalidMigrationError, "Schema versions must be monotonically increasing (gap #{a}->#{b})" if b <= a
      end
      schema
    end

    private

    def validate_schema!
      raw = self.class.validate_definition!(@sql_definition)
      raw.each_with_object({}) do |(k, statements), acc|
        version = Integer(k)
        raise InvalidMigrationError, "Schema step #{version} must be a Hash of named statements" unless statements.is_a?(Hash)
        acc[version] = statements
      end.sort.to_h
    end

    def reject_forbidden_sql!(pending)
      pending.each do |version, statements|
        statements.each do |name, sql|
          if sql.to_s.match?(FORBIDDEN_SQL)
            raise InvalidMigrationError, "Forbidden migration SQL in step #{version}/#{name}"
          end
        end
      end
    end

    def destructive_version?(version)
      @destructive_versions.include?(version.to_i)
    end

    def file_backed?
      @path != ":memory:" && !@path.to_s.start_with?("file:") && File.file?(@path)
    end

    def preflight_source!
      return unless file_backed?
      raise BackupError, "Source not writable: #{File.basename(@path)}" unless File.writable?(@path)
      raise BackupError, "Parent dir not writable" unless File.writable?(File.dirname(@path))
      db = SQLite3::Database.new(@path, readonly: true)
      result = db.get_first_value("PRAGMA quick_check")
      db.close
      raise BackupIntegrityError, "Source quick_check failed: #{result}" unless result.to_s == "ok"
    end

    def with_advisory_lock
      return yield unless file_backed?

      lock_path = @path + ADVISORY_LOCK_SUFFIX
      deadline = monotonic_now + @lock_timeout
      loop do
        io = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
        if io.flock(File::LOCK_EX | File::LOCK_NB)
          @advisory_io = io
          break
        end
        io.close
        raise MigrationBusyError, "Could not acquire migration advisory lock for #{@component} within #{@lock_timeout}s" if monotonic_now >= deadline
        sleep DEFAULT_LOCK_POLL
      end
      yield
    end

    def release_advisory_lock
      return unless @advisory_io
      @advisory_io.flock(File::LOCK_UN)
      @advisory_io.close
    rescue
      nil
    ensure
      @advisory_io = nil
    end

    def with_write_lock
      deadline = monotonic_now + @lock_timeout
      begin
        @conn.transaction(:immediate) { yield }
      rescue SQLite3::BusyException
        raise MigrationBusyError, "Could not acquire SQLite write lock for #{@component} within #{@lock_timeout}s" if monotonic_now >= deadline
        sleep DEFAULT_LOCK_POLL
        retry
      end
    end

    def under_write_lock
      if @conn.respond_to?(:transaction_active?) && @conn.transaction_active?
        yield
      else
        with_write_lock { yield }
      end
    end

    def apply_step!(version, statements)
      @conn.execute("SAVEPOINT litestack_step_#{version}")
      statements.each do |name, sql|
        @conn.execute(sql)
      rescue => e
        @conn.execute("ROLLBACK TO litestack_step_#{version}")
        @conn.execute("RELEASE litestack_step_#{version}")
        raise MigrationError, "Step #{version} statement #{name}: #{e.message}"
      end
      @conn.user_version = version
      @conn.execute("RELEASE litestack_step_#{version}")
    end

    # Three-connection online backup: A holds write lock; B read source; C dest.
    def create_verified_backup!(source_version)
      raise BackupError, "Cannot backup in-memory database" unless file_backed?

      dir = File.dirname(@path)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%L")
      basename = "#{BACKUP_PREFIX}#{source_version}-#{stamp}-#{Process.pid}.sqlite3"
      final = File.join(dir, basename)
      raise BackupPublicationError, "Backup path collision: #{basename}" if File.exist?(final)

      partial = final + ".partial-#{SecureRandom.hex(4)}"
      b_src = nil
      c_dst = nil
      backup = nil
      begin
        # Exclusive create partial at 0600
        fd = File.open(partial, File::RDWR | File::CREAT | File::EXCL, 0o600)
        fd.close

        # B = independent read source (never A)
        b_src = SQLite3::Database.new(@path)
        c_dst = SQLite3::Database.new(partial)

        if b_src.respond_to?(:backup) && defined?(SQLite3::Backup)
          backup = SQLite3::Backup.new(c_dst, "main", b_src, "main")
          steps = 0
          loop do
            rc = backup.step(-1)
            case rc
            when SQLITE_DONE, true
              break
            when SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED, 0, 5, 6
              steps += 1
              raise BackupError, "Backup step retries exhausted (status=#{rc})" if steps > BACKUP_STEP_RETRIES
              sleep DEFAULT_LOCK_POLL
            else
              # Also accept nil/other when sqlite3 gem uses different API
              if rc.nil? || rc == true
                break
              end
              raise BackupError, "Fatal backup step status: #{rc.inspect}"
            end
          end
        elsif b_src.respond_to?(:backup)
          # sqlite3 gem Database#backup(dest) convenience
          b_src.backup(c_dst)
        else
          b_src.execute("VACUUM INTO ?", [partial])
        end
      ensure
        begin
          backup.finish if backup.respond_to?(:finish)
        rescue
          nil
        end
        begin
          c_dst&.close
        rescue
          nil
        end
        begin
          b_src&.close
        rescue
          nil
        end
      end

      # Reopen snapshot read-only for full verification
      verify_snapshot_file!(partial)

      mode = File.stat(@path).mode & 0o777 & 0o600
      File.chmod(mode, partial)
      @backup_checksum = Digest::SHA256.file(partial).hexdigest
      @backup_size = File.size(partial)

      begin
        File.open(partial, "r") { |f| f.fsync }
      rescue
        nil
      end

      # No-replace hard-link publication (same filesystem)
      begin
        File.link(partial, final)
      rescue Errno::EEXIST
        FileUtils.rm_f(partial)
        raise BackupPublicationError, "Backup destination already exists: #{basename}"
      rescue Errno::EXDEV, NotImplementedError, Errno::EPERM => e
        FileUtils.rm_f(partial)
        raise BackupPublicationError, "Hard-link publication unsupported: #{e.class}"
      end

      begin
        File.open(dir, "r") { |f| f.fsync if f.respond_to?(:fsync) }
      rescue
        nil
      end
      FileUtils.rm_f(partial)
      begin
        File.open(dir, "r") { |f| f.fsync if f.respond_to?(:fsync) }
      rescue
        nil
      end

      final
    rescue BackupError, BackupIntegrityError, BackupPublicationError
      FileUtils.rm_f(partial) if partial && File.exist?(partial.to_s)
      raise
    rescue => e
      FileUtils.rm_f(partial) if partial && File.exist?(partial.to_s)
      raise BackupError, "Failed to create backup: #{e.class}: #{e.message}"
    end

    def verify_snapshot_file!(path)
      db = SQLite3::Database.new(path, readonly: true)
      begin
        integrity = db.execute("PRAGMA integrity_check")
        unless integrity.size == 1 && integrity[0][0].to_s == "ok"
          raise BackupIntegrityError, "integrity_check failed: #{integrity.inspect}"
        end
        fk = db.execute("PRAGMA foreign_key_check")
        raise BackupIntegrityError, "foreign_key_check failed: #{fk.inspect}" unless fk.empty?
      ensure
        db.close
      end
    end

    def verify_full!(conn)
      integrity = conn.execute("PRAGMA integrity_check")
      unless integrity.size == 1 && integrity[0][0].to_s == "ok"
        raise MigrationError, "Post-migration integrity_check failed: #{integrity.inspect}"
      end
      fk = conn.execute("PRAGMA foreign_key_check")
      raise MigrationError, "Post-migration foreign_key_check failed: #{fk.inspect}" unless fk.empty?
    end

    def emit(name, **payload)
      event = {event: name, component: @component, **payload}
      @events << event
      @logger&.info { "[litestack.migration] #{name} #{payload.inspect}" }
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.instrument("litestack.#{name}", event)
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
