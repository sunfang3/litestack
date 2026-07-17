# frozen_string_literal: true

require_relative "../../litestack/compatibility"
Litestack::Compatibility.assert_rails_supported!

require_relative "../../litestack/litedb"

require "active_record"
require "active_record/connection_adapters/sqlite3_adapter"
require "active_record/tasks/sqlite_database_tasks"

module ActiveRecord
  module ConnectionAdapters # :nodoc:
    class LitedbAdapter < SQLite3Adapter
      ADAPTER_NAME = "Litedb"

      NATIVE_DATABASE_TYPES = {
        primary_key: "integer PRIMARY KEY NOT NULL",
        string: {name: "text"},
        text: {name: "text"},
        integer: {name: "integer"},
        float: {name: "real"},
        decimal: {name: "real"},
        datetime: {name: "text"},
        time: {name: "integer"},
        date: {name: "text"},
        binary: {name: "blob"},
        boolean: {name: "integer"},
        json: {name: "text"},
        unixtime: {name: "integer"}
      }.freeze

      class << self
        # Rails 8.1 inherited connect calls self.class.new_client(@connection_parameters).
        def new_client(config)
          config = config.symbolize_keys
          unless config[:database]
            raise ArgumentError, "No database file specified. Missing argument: database"
          end

          if config[:database] != ":memory:" && !config[:database].to_s.start_with?("file:")
            config[:database] = File.expand_path(config[:database], Rails.root) if defined?(Rails.root)
            dirname = File.dirname(config[:database])
            Dir.mkdir(dirname) unless File.directory?(dirname)
          end

          ::Litedb.new(
            config[:database].to_s,
            config.merge(results_as_hash: true)
          )
        rescue Errno::ENOENT => error
          if error.message.include?("No such file or directory")
            raise ActiveRecord::NoDatabaseError
          else
            raise
          end
        end

        def dbconsole(config, options = {})
          args = []
          args << "-#{options[:mode]}" if options[:mode]
          args << "-header" if options[:header]
          root = Rails.respond_to?(:root) ? Rails.root : nil
          db_path = config.respond_to?(:database) ? config.database : config[:database]
          args << File.expand_path(db_path.to_s, root)
          find_cmd_and_exec("sqlite3", *args)
        end

        # Lexically override so we never inherit SQLite3Adapter's constant mapping.
        def native_database_types
          NATIVE_DATABASE_TYPES
        end
      end

      def adapter_name
        "litedb"
      end

      def native_database_types
        self.class.native_database_types
      end
    end
  end

  module Tasks # :nodoc:
    class LitedbDatabaseTasks < SQLiteDatabaseTasks # :nodoc:
    end

    module DatabaseTasks
      register_task(/litedb/, "ActiveRecord::Tasks::LitedbDatabaseTasks")
    end
  end
end

if ActiveRecord::ConnectionAdapters.respond_to?(:register)
  ActiveRecord::ConnectionAdapters.register(
    "litedb", "ActiveRecord::ConnectionAdapters::LitedbAdapter",
    "active_record/connection_adapters/litedb_adapter"
  )
end
