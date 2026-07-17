# frozen_string_literal: true

# Built-gem Rails 8.1 application smoke.
# Run via: bundle exec rake integration:rails81

require "minitest/autorun"
require_relative "../support/rails_app_builder"

class Rails81AppTest < Minitest::Test
  def test_built_gem_rails81_smoke
    unless system("which", "rails", out: File::NULL, err: File::NULL)
      flunk "rails executable not on PATH — cannot prove launcher; install rails 8.1 CLI"
    end

    builder = Litestack::RailsAppBuilder.new(root: File.expand_path("../..", __dir__))
    begin
      builder.build_and_install_gem!
      builder.generate_app!
      builder.add_built_gem!
      builder.run_generator!
      out = builder.run_smoke!
      # Emit body-level markers to the harness log (rails81_smoke.log consumers).
      puts out
      assert_match(/SMOKE_OK/, out)
      assert_match(/CRUD_OK/, out)
      assert_match(/CACHE_OK/, out)
      assert_match(/JOB_OK/, out)
      assert_match(/CABLE_OK/, out)
      assert_match(/8\.1/, out)
      assert_match(/Litestack=1\.0\.0/, out)
    ensure
      if builder && !passed?
        warn builder.log.last(80).join("\n")
      end
      builder&.cleanup!
    end
  end

  def test_builder_and_package_structural
    assert File.file?(File.expand_path("../support/rails_app_builder.rb", __dir__))
    assert defined?(Litestack::RailsAppBuilder)
    builder = Litestack::RailsAppBuilder.new
    assert builder.workdir
    builder.cleanup!
  end
end
