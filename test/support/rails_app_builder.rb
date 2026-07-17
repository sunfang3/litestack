# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "bundler"
require "rubygems/package"

module Litestack
  # Builds an isolated Rails 8.1 app that consumes a *built* gem artifact
  # (extracted package), not the repository path source.
  class RailsAppBuilder
    attr_reader :workdir, :app_dir, :gem_home, :package_dir, :log, :gem_file

    def initialize(root: Dir.pwd, workdir: nil)
      @root = root
      @workdir = workdir || Dir.mktmpdir("litestack-rails81-")
      @gem_home = File.join(@workdir, "gem_home")
      @package_dir = File.join(@workdir, "litestack-package")
      @app_dir = File.join(@workdir, "app")
      @log = []
      FileUtils.mkdir_p(@gem_home)
    end

    def build_and_install_gem!
      Dir.chdir(@root) do
        run_unbundled!("gem", "build", "litestack.gemspec")
        @gem_file = Dir[File.join(@root, "litestack-*.gem")].max_by { |f| File.mtime(f) }
        raise "gem build produced no artifact" unless @gem_file

        FileUtils.rm_rf(@package_dir)
        FileUtils.mkdir_p(@package_dir)
        # Extract built gem contents — this is the packaged artifact, not repo lib/
        Gem::Package.new(@gem_file).extract_files(@package_dir)
        # gemspec needed for Bundler path: sources
        unless Dir[File.join(@package_dir, "*.gemspec")].any?
          FileUtils.cp(File.join(@root, "litestack.gemspec"), @package_dir)
          # Rewrite gemspec require_relative version for package layout
          version_rb = File.join(@package_dir, "lib/litestack/version.rb")
          raise "package missing version.rb" unless File.file?(version_rb)
        end
        raise "package missing lib/" unless File.directory?(File.join(@package_dir, "lib"))
        @gem_file
      end
    end

    def ensure_rails_cli!
      # Isolated GEM_HOME so `rails` is available under with_unbundled_env
      # (CI runners often have no global rails binstub).
      run_unbundled!("gem", "install", "bundler", "--no-document")
      run_unbundled!(
        "gem", "install", "rails", "-v", "8.1.3",
        "--no-document", "--force"
      )
      rails_bin = File.join(@gem_home, "bin", "rails")
      raise "rails CLI missing after gem install: #{rails_bin}" unless File.executable?(rails_bin)
      rails_bin
    end

    def generate_app!
      rails = ensure_rails_cli!
      run_unbundled!(
        rails, "new", @app_dir,
        "--minimal", "--skip-test", "--skip-system-test", "--skip-bootsnap",
        "--skip-javascript", "--skip-hotwire", "--skip-asset-pipeline",
        "-d", "sqlite3"
      )
    end

    def add_built_gem!
      raise "call build_and_install_gem! first" unless @package_dir && File.directory?(@package_dir)
      gemfile = File.join(@app_dir, "Gemfile")
      File.open(gemfile, "a") do |f|
        f.puts ""
        f.puts "# Built gem artifact (not repository path source)"
        f.puts "gem \"litestack\", path: #{@package_dir.inspect}"
      end
      Dir.chdir(@app_dir) do
        run_unbundled!("bundle", "install")
      end
    end

    def run_generator!
      Dir.chdir(@app_dir) do
        run_unbundled!("bin/rails", "generate", "litestack:install")
      end
    end

    def smoke_script
      <<~'RUBY'
        require "./config/environment"
        require "logger"
        require "tmpdir"
        require "fileutils"
        require "active_job"
        require "active_job/queue_adapters/litejob_adapter"
        require "action_cable"
        require "action_cable/subscription_adapter/litecable"

        puts "Rails=#{Rails.version} Litestack=#{Litestack::VERSION}"
        raise "Rails not 8.1.x" unless Rails.version.start_with?("8.1")

        # --- Litedb CRUD ---
        ActiveRecord::Base.connection.execute("CREATE TABLE IF NOT EXISTS smoke(id INTEGER PRIMARY KEY, name TEXT)")
        ActiveRecord::Base.connection.execute("INSERT INTO smoke(name) VALUES ('ok')")
        n = ActiveRecord::Base.connection.select_value("SELECT count(*) FROM smoke")
        raise "crud failed count=#{n}" unless n.to_i >= 1
        puts "CRUD_OK count=#{n}"

        work = Dir.mktmpdir("smoke-data-")

        # --- Litecache ---
        cache = ActiveSupport::Cache::Litecache.new(path: File.join(work, "cache.sqlite3"), sleep_interval: 60)
        cache.write("k", "v")
        raise "cache failed" unless cache.read("k") == "v"
        cache.close
        cache.close # double close
        puts "CACHE_OK"

        # --- Litejob (Active Job adapter) ---
        class SmokeJob < ActiveJob::Base
          self.queue_adapter = :litejob
          cattr_accessor :done
          def perform(msg)
            self.class.done = msg
          end
        end
        Litejobqueue.reset_singleton! if Litejobqueue.respond_to?(:reset_singleton!)
        q = Litejobqueue.jobqueue(
          path: File.join(work, "jobs.sqlite3"),
          logger: nil,
          workers: 1,
          sleep_intervals: [0.01],
          queues: [["default", 1], ["test", 1]]
        )
        SmokeJob.done = nil
        SmokeJob.perform_later("job-payload")
        deadline = Time.now + 8
        sleep 0.05 while SmokeJob.done.nil? && Time.now < deadline
        raise "litejob failed done=#{SmokeJob.done.inspect}" unless SmokeJob.done == "job-payload"
        q.stop
        q.stop # double shutdown
        puts "JOB_OK"

        # --- Litecable ---
        FakeConfig = Struct.new(:cable)
        FakeServer = Struct.new(:logger, :config)
        server = FakeServer.new(Logger.new(IO::NULL), FakeConfig.new({"path" => File.join(work, "cable.sqlite3")}))
        cable = ActionCable::SubscriptionAdapter::Litecable.new(server)
        received = []
        sub = ->(msg) { received << msg }
        cable.subscribe("room", sub)
        cable.broadcast("room", "ping")
        sleep 0.2
        raise "cable failed received=#{received.inspect}" unless received.include?("ping")
        cable.shutdown
        cable.shutdown # double shutdown
        puts "CABLE_OK"

        FileUtils.rm_rf(work)
        puts "SMOKE_OK"
      RUBY
    end

    def run_smoke!
      script = File.join(@app_dir, "tmp_smoke.rb")
      File.write(script, smoke_script)
      Dir.chdir(@app_dir) do
        out = run_unbundled!("bin/rails", "runner", script)
        raise "smoke missing SMOKE_OK\n#{out}" unless out.include?("SMOKE_OK")
        raise "smoke missing JOB_OK\n#{out}" unless out.include?("JOB_OK")
        raise "smoke missing CABLE_OK\n#{out}" unless out.include?("CABLE_OK")
        raise "smoke missing CACHE_OK\n#{out}" unless out.include?("CACHE_OK")
        raise "smoke missing CRUD_OK\n#{out}" unless out.include?("CRUD_OK")
        out
      end
    end

    def cleanup!
      FileUtils.rm_rf(@workdir)
    end

    private

    def unbundled_env
      env = ENV.to_h.dup
      %w[
        BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_ORIG_PATH BUNDLER_ORIG_MANPATH
        BUNDLER_VERSION BUNDLE_PATH BUNDLE_APP_CONFIG RUBYGEMS_GEMDEPS
      ].each { |k| env.delete(k) }
      env["GEM_HOME"] = @gem_home
      env["GEM_PATH"] = @gem_home
      gem_bin = File.join(@gem_home, "bin")
      env["PATH"] = [gem_bin, env["PATH"].to_s].reject(&:empty?).join(File::PATH_SEPARATOR)
      if env["RUBYOPT"]
        env["RUBYOPT"] = env["RUBYOPT"].split(/\s+/).reject { |o| o.include?("bundler/setup") }.join(" ")
      end
      env
    end

    def run_unbundled!(*cmd)
      @log << cmd.join(" ")
      out = err = ""
      st = nil
      Bundler.with_unbundled_env do
        out, err, st = Open3.capture3(unbundled_env, *cmd)
      end
      @log << out
      @log << err unless err.empty?
      raise "command failed: #{cmd.join(" ")}\n#{out}\n#{err}" unless st.success?
      out
    end
  end
end
