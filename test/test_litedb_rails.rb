# frozen_string_literal: true

require_relative "helper"
require "active_record"
require "active_record/connection_adapters/litedb_adapter"

class TestLitedbRails < Minitest::Test
  def setup
    @path, @dir = tmp_sqlite_path("ar-litedb")
    ActiveRecord::Base.establish_connection(adapter: "litedb", database: @path)
    ActiveRecord::Schema.define do
      create_table :widgets, force: true do |t|
        t.string :name
        t.timestamps
      end
    end

    Object.send(:remove_const, :Widget) if defined?(Widget)
    Object.const_set(:Widget, Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
    end)
  end

  def teardown
    ActiveRecord::Base.connection_handler.clear_all_connections!
    # Restore a default in-memory connection so other AR tests are not left without a DB.
    ActiveRecord::Base.establish_connection(adapter: "litedb", database: ":memory:")
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_adapter_name
    assert_equal "litedb", ActiveRecord::Base.connection.adapter_name.downcase
  end

  def test_crud
    w = Widget.create!(name: "gizmo")
    assert_equal "gizmo", Widget.find(w.id).name
    w.update!(name: "gadget")
    assert_equal "gadget", Widget.find(w.id).name
    w.destroy!
    assert_equal 0, Widget.count
  end

  def test_missing_database_arg
    err = assert_raises(StandardError) do
      ActiveRecord::Base.establish_connection(adapter: "litedb")
      ActiveRecord::Base.connection
    end
    assert_match(/database|No database|argument/i, err.message)
  ensure
    ActiveRecord::Base.establish_connection(adapter: "litedb", database: @path)
  end

  def test_memory_path
    ActiveRecord::Base.establish_connection(adapter: "litedb", database: ":memory:")
    ActiveRecord::Base.connection.execute("CREATE TABLE t(id INTEGER PRIMARY KEY)")
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT count(*) FROM t")
  end

  def test_dbconsole_class_method
    assert_respond_to ActiveRecord::ConnectionAdapters::LitedbAdapter, :dbconsole
  end

  def test_no_monkey_patch_file
    refute File.exist?(File.expand_path("patch_ar_adapter_path.rb", __dir__))
  end
end
