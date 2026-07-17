# frozen_string_literal: true

require_relative "helper"
require "rails"
require "rails/generators"
require "fileutils"
require "generators/litestack/install/install_generator"

class TestInstallGenerator < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rails-app-")
    FileUtils.mkdir_p(File.join(@root, "config/environments"))
    File.write(File.join(@root, "config/database.yml"), <<~YAML)
      default: &default
        adapter: sqlite3
        pool: 5
      development:
        <<: *default
        database: db/development.sqlite3
      test:
        <<: *default
        database: db/test.sqlite3
      production:
        <<: *default
        database: db/production.sqlite3
    YAML
    File.write(File.join(@root, "config/cable.yml"), <<~YAML)
      development:
        adapter: async
      test:
        adapter: test
      production:
        adapter: redis
    YAML
    File.write(File.join(@root, "config/environments/production.rb"), <<~RUBY)
      require "active_support/core_ext/integer/time"
      Rails.application.configure do
        # config.cache_store = :mem_cache_store
        # config.active_job.queue_adapter     = :resque
      end
    RUBY
    File.write(File.join(@root, ".gitignore"), "/log/*\n")
    File.write(File.join(@root, ".dockerignore"), "/log\n/tmp\n")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def run_generator(args = [])
    Dir.chdir(@root) do
      Rails::Generators.invoke("litestack:install", args, behavior: :invoke, destination_root: @root)
    end
  end

  def test_happy_path_configures_adapters
    run_generator
    db = File.read(File.join(@root, "config/database.yml"))
    cable = File.read(File.join(@root, "config/cable.yml"))
    prod = File.read(File.join(@root, "config/environments/production.rb"))
    git = File.read(File.join(@root, ".gitignore"))
    docker = File.read(File.join(@root, ".dockerignore"))

    assert_match(/adapter:\s*litedb/, db)
    assert_match(/adapter:\s*litecable/, cable)
    assert_match(/cache_store = :litecache/, prod)
    assert_match(/queue_adapter = :litejob/, prod)
    assert_match(/sqlite3/, git)
    # issue #119: same SQLite exclusions in .dockerignore
    assert_match(%r{/db/\*\*/\*\.sqlite3}, docker)
    assert_match(%r{/db/\*\*/\*\.sqlite3-\*}, docker)
    assert_match(/Ignore default Litestack SQLite databases/, docker)

    ext_init = File.join(@root, "config/initializers/litestack_extensions.rb")
    assert File.file?(ext_init), "expected litestack_extensions initializer"
    init_body = File.read(ext_init)
    assert_match(/simple_extension_path/, init_body)
    assert_match(/vector_extension_path/, init_body)
    assert_match(/vendor\/simple/, init_body)
    assert_match(/vendor\/vectorlite/, git)
  end

  def test_idempotent_second_run
    run_generator
    run_generator
    git = File.read(File.join(@root, ".gitignore"))
    docker = File.read(File.join(@root, ".dockerignore"))
    assert_equal 1, git.scan("Ignore default Litestack SQLite databases").size
    assert_equal 1, docker.scan("Ignore default Litestack SQLite databases").size
  end

  def test_dockerignore_absent_is_skipped_safely
    FileUtils.rm_f(File.join(@root, ".dockerignore"))
    run_generator
    refute File.exist?(File.join(@root, ".dockerignore")),
      "generator must not create .dockerignore when missing"
    git = File.read(File.join(@root, ".gitignore"))
    assert_match(%r{/db/\*\*/\*\.sqlite3}, git)
  end

  def test_multi_database_preserves_entries
    File.write(File.join(@root, "config/database.yml"), <<~YAML)
      default: &default
        adapter: sqlite3
        pool: 5
      development:
        primary:
          <<: *default
          database: db/primary.sqlite3
        cable:
          <<: *default
          database: db/cable.sqlite3
          migrations_paths: db/cable_migrate
    YAML
    run_generator
    db = File.read(File.join(@root, "config/database.yml"))
    assert_match(/cable:/, db)
    assert_match(/primary:/, db)
    assert_match(/adapter:\s*litedb/, db)
  end

  def with_fetch_hook
    fetches = []
    Litestack::InstallGenerator.extension_fetch_hook = lambda { |gen, kind, _label|
      fetches << kind
      platform = "linux-x86_64"
      base = (kind == "simple") ? "simple" : "vectorlite"
      name = (kind == "simple") ? "libsimple.so" : "vectorlite.so"
      dir = File.join(gen.destination_root, "vendor", base, platform)
      FileUtils.mkdir_p(dir)
      File.binwrite(File.join(dir, name), "stub")
    }
    yield fetches
  ensure
    Litestack::InstallGenerator.extension_fetch_hook = nil
  end

  def test_with_extensions_flags_invoke_fetch
    with_fetch_hook do |fetches|
      run_generator(["--with-extensions"])
      assert_equal %w[simple vectorlite], fetches
      assert File.file?(File.join(@root, "vendor/simple/linux-x86_64/libsimple.so"))
      assert File.file?(File.join(@root, "vendor/vectorlite/linux-x86_64/vectorlite.so"))
    end
  end

  def test_with_simple_only_fetches_simple
    with_fetch_hook do |fetches|
      run_generator(["--with-simple"])
      assert_equal %w[simple], fetches
    end
  end

  def test_with_vectorlite_only_fetches_vectorlite
    with_fetch_hook do |fetches|
      run_generator(["--with-vectorlite"])
      assert_equal %w[vectorlite], fetches
    end
  end

  def test_skip_fetch_env_skips_download
    with_fetch_hook do |fetches|
      ENV["LITESTACK_GENERATOR_SKIP_FETCH"] = "1"
      run_generator(["--with-extensions"])
      assert_empty fetches
    ensure
      ENV.delete("LITESTACK_GENERATOR_SKIP_FETCH")
    end
  end

  def test_without_flags_does_not_fetch
    with_fetch_hook do |fetches|
      run_generator
      assert_empty fetches
    end
  end
end
