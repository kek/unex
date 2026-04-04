defmodule Uniops.Storage.CellTest do
  use ExUnit.Case, async: false

  alias Uniops.Storage.{Schema, Database, Cell}

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_cell_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Schema.init(dir)
    Database.create("testdb")

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "write and read" do
    Cell.write("testdb", "counter", 42)
    assert {:ok, 42} = Cell.read("testdb", "counter")
  end

  test "read returns :not_found for missing cell" do
    assert :not_found = Cell.read("testdb", "missing")
  end

  test "overwrite replaces value" do
    Cell.write("testdb", "val", "first")
    Cell.write("testdb", "val", "second")
    assert {:ok, "second"} = Cell.read("testdb", "val")
  end
end
