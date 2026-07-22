# frozen_string_literal: true

require_relative "helper"
require "yaml"

describe "examples/honker_rails overlays" do
  EXAMPLE = File.expand_path("../examples/honker_rails", __dir__)

  it "ships expected overlay files" do
    %w[
      README.md
      config/litejob.yml
      config/litecache.yml
      config/cable.yml
      config/initializers/honker_ar_setup.rb
      app/jobs/demo_honker_job.rb
      script/smoke_honker.rb
    ].each do |rel|
      path = File.join(EXAMPLE, rel)
      assert File.file?(path), "missing #{rel}"
    end
  end

  it "litejob.yml enables honker backend/wakeup/lifecycle in development" do
    yml = YAML.safe_load_file(File.join(EXAMPLE, "config/litejob.yml"))
    dev = yml.fetch("development")
    assert_equal "honker", dev["wakeup"].to_s
    assert_equal "honker", dev["backend"].to_s
    assert dev["lifecycle_stream"]
    assert dev["job_results"]
  end

  it "litecache.yml enables L1 + honker invalidate in development" do
    yml = YAML.safe_load_file(File.join(EXAMPLE, "config/litecache.yml"))
    dev = yml.fetch("development")
    assert dev["l1"]
    assert_equal "honker", dev["invalidate"].to_s
  end

  it "cable.yml uses litecable + honker transport" do
    yml = YAML.safe_load_file(File.join(EXAMPLE, "config/cable.yml"))
    dev = yml.fetch("development")
    assert_equal "litecable", dev["adapter"].to_s
    assert_equal "honker", dev["transport"].to_s
  end

  it "create script documents DEST and is executable-ish" do
    script = File.expand_path("../scripts/create_honker_rails_app.rb", __dir__)
    assert File.file?(script)
    body = File.read(script)
    assert_match(/rails new/, body)
    assert_match(/examples\/honker_rails/, body)
    assert_match(/honker/, body)
  end
end
