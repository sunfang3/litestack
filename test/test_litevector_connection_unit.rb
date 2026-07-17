# frozen_string_literal: true

# Connection mixin without real vectorlite binary.

require_relative "helper"
require "litestack/litevector"
require "sqlite3"
require "fileutils"

class TestLitevectorConnectionUnit < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("lv-conn-unit-")
    Litevector::Extension.load_hook = lambda { |db|
      db.instance_variable_set(:@hooked, true)
      "/fake.so"
    }
    @fake_index = Object.new
    def @fake_index.open!
      self
    end
    def @fake_index.close
    end

    @orig_new = Litevector::Index.method(:new)
    @orig_open = Litevector::Index.method(:open)
    fake = @fake_index
    Litevector::Index.define_singleton_method(:new) { |**_| fake }
    Litevector::Index.define_singleton_method(:open) { |**_| fake }
  end

  def teardown
    Litevector::Extension.load_hook = nil
    Litevector::Index.define_singleton_method(:new, @orig_new)
    Litevector::Index.define_singleton_method(:open, @orig_open)
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_ensure_and_info
    db = SQLite3::Database.new(":memory:")
    db.extend(Litevector::Connection)
    assert_same db, db.ensure_vectorlite!
    assert Litevector::Extension.loaded?(db)
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
    assert_same @fake_index, idx

    opened = db.vector_index(:x, data_path: @tmpdir)
    assert_same @fake_index, opened
  end
end
