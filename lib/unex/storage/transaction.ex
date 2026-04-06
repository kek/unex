defmodule Unex.Storage.Transaction do
  @moduledoc """
  Executes a list of storage operations in a single Mnesia transaction.
  """

  alias Unex.Storage.{OrderedTable, Cell}

  def execute(db, ops) do
    # Ensure cell table exists before entering transaction
    Cell.__ensure_table__(db)

    result =
      :mnesia.transaction(fn ->
        Enum.map(ops, fn op -> execute_op(db, op) end)
      end)

    case result do
      {:atomic, results} -> {:ok, results}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp execute_op(db, {:write_table, table, key, value}) do
    tab = OrderedTable.table_name(db, table)
    :mnesia.write({tab, key, value})
  end

  defp execute_op(db, {:read_table, table, key}) do
    tab = OrderedTable.table_name(db, table)

    case :mnesia.read(tab, key) do
      [{^tab, ^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  defp execute_op(db, {:delete_table, table, key}) do
    tab = OrderedTable.table_name(db, table)
    :mnesia.delete({tab, key})
  end

  defp execute_op(db, {:write_cell, name, value}) do
    tab = Cell.table_name(db)
    :mnesia.write({tab, name, value})
  end

  defp execute_op(db, {:read_cell, name}) do
    tab = Cell.table_name(db)

    case :mnesia.read(tab, name) do
      [{^tab, ^name, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  defp execute_op(_db, op) do
    :mnesia.abort({:unknown_operation, op})
  end
end
