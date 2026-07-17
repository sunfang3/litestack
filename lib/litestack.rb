# frozen_string_literal: true

# load core classes
require_relative "litestack/version"
require_relative "litestack/compatibility"
require_relative "litestack/litescheduler"
require_relative "litestack/litesupport"

# auto load each of these when/if needed
require_relative "litestack/litemetric"
require_relative "litestack/litedb"
require_relative "litestack/litecache"
require_relative "litestack/litejob"
require_relative "litestack/litecable"
require_relative "litestack/litekd"

# Conditionally load optional peer integrations.
# Rails version gating happens inside each Rails-facing entry point — not here —
# so `require "litestack"` stays Rails-free.
require_relative "sequel/adapters/litedb" if defined? Sequel
require_relative "active_record/connection_adapters/litedb_adapter" if defined? ActiveRecord
require_relative "active_support/cache/litecache" if defined? ActiveSupport
require_relative "active_job/queue_adapters/litejob_adapter" if defined? ActiveJob
require_relative "action_cable/subscription_adapter/litecable" if defined? ActionCable
require_relative "litestack/railtie" if defined? Rails::Railtie

module Litestack
  class NotImplementedError < RuntimeError; end

  class TimeoutError < RuntimeError; end

  class DeadlockError < RuntimeError; end

  # Lifecycle: operation on a closed connection/component.
  class ClosedError < RuntimeError; end

  # Lifecycle: graceful shutdown timed out waiting for workers.
  class ShutdownTimeoutError < RuntimeError; end

  # Schema migrator: cannot acquire cooperative lock (another migrator or writer).
  class MigrationBusyError < RuntimeError; end

  # Schema migrator: preflight/validation/schema failure.
  class MigrationError < RuntimeError; end

  # Schema migrator: invalid YAML / forbidden statements in migration SQL.
  class InvalidMigrationError < MigrationError; end

  # Schema migrator: backup creation or verification failure.
  class BackupError < RuntimeError; end

  # Schema migrator: snapshot failed integrity / foreign-key / semantic checks.
  class BackupIntegrityError < BackupError; end

  # Schema migrator: hard-link/fsync/no-replace publication failure.
  class BackupPublicationError < BackupError; end
end
