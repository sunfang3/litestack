# frozen_string_literal: true

module Litestack
  # Rewrite LiteQueue SQL YAML so physical objects use a configurable prefix
  # (e.g. table_prefix: "litestack_" → table litestack_queue).
  #
  # Used when co-locating the job queue on the Rails primary SQLite file so
  # a bare table name "queue" does not collide with app tables.
  module SqlTablePrefix
    module_function

    # Only [A-Za-z0-9_]; empty string means no prefix.
    def sanitize(prefix)
      s = prefix.to_s
      return "" if s.empty?

      cleaned = s.gsub(/[^A-Za-z0-9_]/, "")
      raise ArgumentError, "table_prefix #{prefix.inspect} is invalid" if cleaned.empty?

      cleaned
    end

    def table_name(prefix)
      p = sanitize(prefix)
      p.empty? ? "queue" : "#{p}queue"
    end

    def apply_sql_text(sql, prefix)
      p = sanitize(prefix)
      return sql if p.empty? || sql.nil?

      table = "#{p}queue"
      sql.to_s
        # Index names like idx_queue_by_name (underscore is a word char — match prefix)
        .gsub(/\bidx_queue_/, "idx_#{p}queue_")
        .gsub(/\bqueue\b/, table)
    end

    # Deep-copy a SchemaMigrator SQL definition hash and rewrite all strings.
    def apply_definition(sql_definition, prefix)
      p = sanitize(prefix)
      return sql_definition if p.empty? || sql_definition.nil?

      deep_map(sql_definition) do |value|
        value.is_a?(String) ? apply_sql_text(value, p) : value
      end
    end

    def deep_map(obj, &block)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          h[k] = deep_map(v, &block)
        end
      when Array
        obj.map { |v| deep_map(v, &block) }
      else
        yield obj
      end
    end
  end
end
