# frozen_string_literal: true

class Litestack::InstallGenerator < Rails::Generators::Base
  source_root File.expand_path("templates", __dir__)

  desc "Install Litestack adapters for database, cache, jobs, and Action Cable"

  def modify_database_adapter
    if File.exist?(File.join(destination_root, "config/database.yml"))
      # Prefer structured merge of adapter/database keys without wiping multi-db config
      content = File.read(File.join(destination_root, "config/database.yml"))
      if content.include?("adapter: litedb")
        say_status :skip, "config/database.yml already uses litedb", :yellow
      elsif multi_database_config?(content)
        inject_litedb_into_existing_database_yml(content)
      else
        template "database.yml", "config/database.yml"
      end
    else
      template "database.yml", "config/database.yml"
    end
  end

  def modify_action_cable_adapter
    if File.exist?(File.join(destination_root, "config/cable.yml"))
      content = File.read(File.join(destination_root, "config/cable.yml"))
      if content.include?("adapter: litecable")
        say_status :skip, "config/cable.yml already uses litecable", :yellow
      else
        template "cable.yml", "config/cable.yml"
      end
    else
      template "cable.yml", "config/cable.yml"
    end
  end

  def modify_cache_store_adapter
    production = File.join(destination_root, "config/environments/production.rb")
    return unless File.exist?(production)

    content = File.read(production)
    if content.match?(/config\.cache_store\s*=\s*:litecache/)
      say_status :skip, "production cache_store already litecache", :yellow
      return
    end

    if content.match?(/#\s*config\.cache_store\s*=\s*:mem_cache_store/)
      gsub_file "config/environments/production.rb",
        /#\s*config\.cache_store\s*=\s*:mem_cache_store/,
        "config.cache_store = :litecache"
    elsif content.match?(/config\.cache_store\s*=/)
      gsub_file "config/environments/production.rb",
        /config\.cache_store\s*=.*/,
        "config.cache_store = :litecache"
    else
      inject_into_file "config/environments/production.rb",
        "\n  config.cache_store = :litecache\n",
        before: /^end\s*\z/
    end
  end

  def modify_active_job_adapter
    production = File.join(destination_root, "config/environments/production.rb")
    return unless File.exist?(production)

    content = File.read(production)
    if content.match?(/config\.active_job\.queue_adapter\s*=\s*:litejob/)
      say_status :skip, "production queue_adapter already litejob", :yellow
      return
    end

    if content.match?(/#\s*config\.active_job\.queue_adapter/)
      gsub_file "config/environments/production.rb",
        /#\s*config\.active_job\.queue_adapter.*/,
        "config.active_job.queue_adapter = :litejob"
    elsif content.match?(/config\.active_job\.queue_adapter\s*=/)
      gsub_file "config/environments/production.rb",
        /config\.active_job\.queue_adapter\s*=.*/,
        "config.active_job.queue_adapter = :litejob"
    else
      inject_into_file "config/environments/production.rb",
        "\n  config.active_job.queue_adapter = :litejob\n",
        before: /^end\s*\z/
    end
  end

  def modify_gitignore
    append_sqlite_ignore_patterns(
      ".gitignore",
      marker: "# Ignore default Litestack SQLite databases."
    )
  end

  # Rails 7.1+ ships a default Dockerfile + .dockerignore; keep pack excludes
  # aligned with .gitignore so development SQLite files are not baked into images
  # (https://github.com/oldmoe/litestack/issues/119).
  def modify_dockerignore
    dockerignore = File.join(destination_root, ".dockerignore")
    unless File.exist?(dockerignore)
      say_status :skip, ".dockerignore not present (nothing to update)", :yellow
      return
    end

    append_sqlite_ignore_patterns(
      ".dockerignore",
      marker: "# Ignore default Litestack SQLite databases."
    )
  end

  def create_extensions_initializer
    template "litestack_extensions.rb", "config/initializers/litestack_extensions.rb"
  end

  def modify_gitignore_for_extensions
    path = File.join(destination_root, ".gitignore")
    return unless File.exist?(path)

    marker = "# Litestack optional SQLite extensions (fetch at build/deploy)"
    content = File.read(path)
    if content.include?(marker) || content.include?("/vendor/simple/**/*.so")
      say_status :skip, ".gitignore already ignores extension binaries", :yellow
      return
    end

    append_file ".gitignore", <<~TEXT

      #{marker}
      /vendor/simple/**/*.so
      /vendor/simple/**/*.dylib
      /vendor/simple/**/*.dll
      /vendor/vectorlite/**/*.so
      /vendor/vectorlite/**/*.dylib
      /vendor/vectorlite/**/*.dll
    TEXT
  end

  def print_optional_solid_cleanup
    say ""
    say "Litestack core stack installed (Litedb / Litecache / Litejob / Litecable).", :green
    say ""
    say "Optional native extensions (NOT installed by this generator):", :yellow
    say "  Chinese/Pinyin FTS → libsimple   |  Vector kNN → vectorlite"
    say "  From the Rails root:"
    say "    export LITESTACK_EXTENSION_ROOT=\"$PWD\""
    say "    bundle exec ruby \"$(bundle show litestack)/scripts/fetch_simple.rb\""
    say "    bundle exec ruby \"$(bundle show litestack)/scripts/fetch_vectorlite.rb\""
    say "  Paths are wired in config/initializers/litestack_extensions.rb when files exist."
    say "  Full guide: docs/RAILS_FULL_STACK.md (in the litestack gem / repo)."
    say ""
    say "Optional cleanup if you do not need Solid Cache/Queue:", :green
    say "  - Remove solid_cache / solid_queue gems from the Gemfile (manual)"
    say "  - Remove their migrations and solid_* config if present (manual)"
    say "  - The generator never auto-deletes Solid gems, migrations, or Gemfile lines."
    say "See docs/MIGRATING_TO_RUBY4_RAILS81.md for upgrade and backup steps."
  end

  private

  SQLITE_IGNORE_PATTERNS = [
    "/db/**/*.sqlite3",
    "/db/**/*.sqlite3-*"
  ].freeze

  def append_sqlite_ignore_patterns(relative_path, marker:)
    path = File.join(destination_root, relative_path)
    return unless File.exist?(path)

    content = File.read(path)
    if content.include?(marker) || content.include?("/db/**/*.sqlite3")
      say_status :skip, "#{relative_path} already ignores Litestack SQLite files", :yellow
      return
    end

    append_file relative_path, <<~TEXT

      #{marker}
      #{SQLITE_IGNORE_PATTERNS.join("\n")}
    TEXT
  end

  def multi_database_config?(content)
    content.scan(/^\s*\w+:/).size > 6 || content.include?("primary:")
  end

  def inject_litedb_into_existing_database_yml(content)
    # Replace adapter: sqlite3 with adapter: litedb on primary-like entries only
    new_content = content.gsub(/adapter:\s*sqlite3/, "adapter: litedb")
    if new_content == content
      say_status :error, "Unrecognized database.yml; set adapter: litedb manually", :red
      raise Thor::Error, "Could not update config/database.yml safely"
    else
      File.write(File.join(destination_root, "config/database.yml"), new_content)
      say_status :update, "config/database.yml (adapter -> litedb)", :green
    end
  end
end

