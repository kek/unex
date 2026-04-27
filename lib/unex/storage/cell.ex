defmodule Unex.Storage.Cell do
  @moduledoc """
  Single durable value store. All cells in a database share one Mnesia set table.
  """

  def table_name(db) do
    :"unex_cells_#{db}"
  end

  def write(db, name, value) do
    ensure_table(db)
    tab = table_name(db)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({tab, name, value}) end)
    :ok
  end

  def read(db, name) do
    ensure_table(db)
    tab = table_name(db)

    {:atomic, result} = :mnesia.transaction(fn -> :mnesia.read(tab, name) end)

    case result do
      [{^tab, ^name, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @doc false
  def __ensure_table__(db), do: ensure_table(db)

  defp ensure_table(db) do
    tab = table_name(db)
    Unex.Storage.Schema.ensure_table!(tab, type: :set, attributes: [:name, :value])
    :ok = :mnesia.wait_for_tables([tab], 5_000)
    :ok
  end
end
