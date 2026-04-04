defmodule Uniops.Storage.TransactionTest do
  use ExUnit.Case, async: false

  alias Uniops.Storage.{Schema, Database, OrderedTable, Cell, Transaction}

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_tx_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Schema.init(dir)
    Database.create("testdb")
    OrderedTable.ensure("testdb", "t1")

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "commits all ops atomically" do
    ops = [
      {:write_table, "t1", "k1", "v1"},
      {:write_cell, "counter", 10}
    ]

    assert {:ok, _} = Transaction.execute("testdb", ops)
    assert {:ok, "v1"} = OrderedTable.read("testdb", "t1", "k1")
    assert {:ok, 10} = Cell.read("testdb", "counter")
  end

  test "rolls back on invalid op" do
    OrderedTable.write("testdb", "t1", "k1", "original")

    ops = [
      {:write_table, "t1", "k1", "changed"},
      {:bogus_op, "bad"}
    ]

    assert {:error, _} = Transaction.execute("testdb", ops)
    assert {:ok, "original"} = OrderedTable.read("testdb", "t1", "k1")
  end

  test "mixed table and cell ops" do
    ops = [
      {:write_table, "t1", "a", "1"},
      {:write_cell, "flag", true},
      {:delete_table, "t1", "a"}
    ]

    assert {:ok, _} = Transaction.execute("testdb", ops)
    assert :not_found = OrderedTable.read("testdb", "t1", "a")
    assert {:ok, true} = Cell.read("testdb", "flag")
  end

  test "read ops return values" do
    OrderedTable.write("testdb", "t1", "x", "y")
    Cell.write("testdb", "mycell", 99)

    ops = [
      {:read_table, "t1", "x"},
      {:read_cell, "mycell"}
    ]

    assert {:ok, results} = Transaction.execute("testdb", ops)
    assert results == [{:ok, "y"}, {:ok, 99}]
  end
end
