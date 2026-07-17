# frozen_string_literal: true

# Connection mixin without real vectorlite binary.

require_relative "helper"
require "litestack/litevector"
require "sqlite3"
require "fileutils"

class TestLitevectorConnectionUnit < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("lv-conn-unit-")
    @orig_load = Litevector::Extension.method(:load!)
    @orig_new = Litevector::Index.method(:new)
    @orig_open = Litevector::Index.method(:open)

    Litevector::Extension.define_singleton_method(:load!) { |db| db.instance_variable_set(:@lv, true); "/fake.so" }

    fake = Object.new
    def fake.open!
      self
    end
    def fake.close
    end
    Litevector::Index.define_singleton_method(:new) { |**_| fake }
    Litevector::Index.define_singleton_method(:open) { |**_| fake }
    @fake = fake
  end

  def teardown
    Litevector::Extension.define_singleton_method(:load!, @orig_load)
    Litevector::Index.define_singleton_method(:new, @orig_new)
    Litevector::Index.define_singleton_method(:open, @orig_open)
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_ensure_and_info
    db = SQLite3::Database.new(":memory:")
    db.extend(Litevector::Connection)
    assert_same db, db.ensure_vectorlite!
    # Connection#vectorlite_info runs SQL; stub get_first_value after load
    def db.get_first_value(*)
      "fake-info"
    end
    assert_equal "fake-info", db.vectorlite_info
  end

  def test_vector_index_block_and_open
    db = SQLite3::Database.new(":memory:")
    db.extend(Litevector::Connection)
    idx = db.vector_index(:x, data_path: @tmpdir) do |s|
      s.dimensions 2
      s.max_elements 10
    end
    assert_same @fake, idx

    opened = db.vector_index(:x, data_path: @tmpdir)
    assert_same @fake, opened
  end
end
