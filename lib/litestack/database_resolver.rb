# frozen_string_literal: true

module Litestack
  # Resolves a SQLite file path for LiteJob when sharing the app primary
  # (or named) Active Record database — the foundation of transactional outbox.
  module DatabaseResolver
    module_function

    # +spec+ may be:
    #   :primary / "primary" / true  → AR primary connection
    #   :litejob / nil               → caller keeps options[:path]
    #   other Symbol/String          → AR connection name (multi-db)
    #   Hash with :database key      → explicit path string
    def resolve_path(spec, options = {})
      case spec
      when nil, :litejob, "litejob", false
        options[:path]
      when true, :primary, "primary"
        sqlite_path_for(options[:database_name] || options[:ar_connection] || "primary")
      when Hash
        spec[:database] || spec["database"] || options[:path]
      else
        sqlite_path_for(spec)
      end
    end

    def sqlite_path_for(connection_name = "primary")
      unless defined?(ActiveRecord::Base)
        raise ArgumentError,
          "database: #{connection_name.inspect} requires ActiveRecord"
      end

      name = connection_name.to_s
      path = path_from_connection_handler(name) ||
        path_from_configurations(name) ||
        path_from_base_connection(name)

      if path.nil? || path.to_s.empty?
        raise ArgumentError,
          "could not resolve SQLite path for ActiveRecord connection #{name.inspect}"
      end

      File.expand_path(path.to_s)
    end

    def path_from_connection_handler(name)
      return nil unless ActiveRecord::Base.respond_to?(:connection_handler)

      pool = ActiveRecord::Base.connection_handler.connection_pool_list(:writing).find do |p|
        cfg = p.db_config
        cfg && (cfg.name.to_s == name || (name == "primary" && cfg.name.to_s == "primary"))
      end
      return nil unless pool

      db = pool.db_config.database
      return nil if db.nil? || db.to_s == ":memory:"

      db
    rescue
      nil
    end

    def path_from_configurations(name)
      env = if defined?(Rails) && Rails.respond_to?(:env)
        Rails.env.to_s
      else
        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "default"
      end

      configs = ActiveRecord::Base.configurations
      cfg = if configs.respond_to?(:configs_for)
        configs.configs_for(env_name: env, name: name) ||
          (name == "primary" && configs.configs_for(env_name: env, name: "primary"))
      end
      return nil unless cfg

      db = cfg.database
      return nil if db.nil? || db.to_s == ":memory:"

      db
    rescue
      nil
    end

    def path_from_base_connection(name)
      return nil unless name.to_s == "primary" || name.to_s == ActiveRecord::Base.connection_db_config&.name.to_s

      db = ActiveRecord::Base.connection_db_config&.database
      return nil if db.nil? || db.to_s == ":memory:"

      db
    rescue
      nil
    end
  end
end
