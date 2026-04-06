defmodule Unex.Storage.OrderedTableTest do
  use ExUnit.Case, async: false

  alias Unex.Storage.{Schema, Database, OrderedTable}

  setup do
    dir = Path.join(System.tmp_dir!(), "unex_ot_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Schema.init(dir)
    Database.create("testdb")

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "ensure/2 is idempotent" do
    assert :ok = OrderedTable.ensure("testdb", "mytable")
    assert :ok = OrderedTable.ensure("testdb", "mytable")
  end

  test "write and read" do
    OrderedTable.ensure("testdb", "t1")
    OrderedTable.write("testdb", "t1", "key1", "value1")
    assert {:ok, "value1"} = OrderedTable.read("testdb", "t1", "key1")
  end

  test "read returns :not_found for missing key" do
    OrderedTable.ensure("testdb", "t1")
    assert :not_found = OrderedTable.read("testdb", "t1", "missing")
  end

  test "overwrite replaces value" do
    OrderedTable.ensure("testdb", "t1")
    OrderedTable.write("testdb", "t1", "k", "v1")
    OrderedTable.write("testdb", "t1", "k", "v2")
    assert {:ok, "v2"} = OrderedTable.read("testdb", "t1", "k")
  end

  test "delete removes key" do
    OrderedTable.ensure("testdb", "t1")
    OrderedTable.write("testdb", "t1", "k", "v")
    OrderedTable.delete("testdb", "t1", "k")
    assert :not_found = OrderedTable.read("testdb", "t1", "k")
  end

  test "scan returns sorted range" do
    OrderedTable.ensure("testdb", "t1")
    OrderedTable.write("testdb", "t1", "b", "2")
    OrderedTable.write("testdb", "t1", "a", "1")
    OrderedTable.write("testdb", "t1", "d", "4")
    OrderedTable.write("testdb", "t1", "c", "3")

    result = OrderedTable.scan("testdb", "t1", "b", "d")
    assert result == [{"b", "2"}, {"c", "3"}, {"d", "4"}]
  end

  test "scan returns empty list when no keys in range" do
    OrderedTable.ensure("testdb", "t1")
    OrderedTable.write("testdb", "t1", "a", "1")
    assert OrderedTable.scan("testdb", "t1", "m", "z") == []
  end
end
