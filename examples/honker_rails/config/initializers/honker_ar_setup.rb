# frozen_string_literal: true

# Honker 0.4.0's Railtie calls Honker.bootstrap(AR connection) without first
# load_extension, which raises "no such function: honker_bootstrap".
# Load the extension (and patch bootstrap) so after_initialize succeeds when
# the gem is present. Safe no-op when honker is not installed.
#
# Copied into the scaffolded app by scripts/create_honker_rails_app.rb.

begin
  gem "honker"
  require "honker"

  module Honker
    class << self
      alias_method :__litestack_demo_bootstrap_raw, :bootstrap unless method_defined?(:__litestack_demo_bootstrap_raw)

      def bootstrap(sqlite_conn)
        # ActiveRecord may pass an AR adapter; unwrap raw SQLite3 handle if needed.
        raw = if sqlite_conn.respond_to?(:raw_connection)
          sqlite_conn.raw_connection
        else
          sqlite_conn
        end
        begin
          load_extension(raw)
        rescue Honker::Error, SQLite3::Exception
          # Extension may already be loaded on this connection.
        end
        __litestack_demo_bootstrap_raw(raw)
      end
    end
  end
rescue LoadError
  # optional peer (includes Gem::LoadError) — leave boot alone if missing
end
