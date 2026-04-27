defmodule Unex.Storage.OrderedTable do
  @moduledoc """
  Sorted key-value store backed by Mnesia ordered_set tables.
  """

  def table_name(db, table) do
    :"unex_ot_#{db}_#{table}"
  end

  def ensure(db, table) do
    tab = table_name(db, table)
    Unex.Storage.Schema.ensure_table!(tab, type: :ordered_set, attributes: [:key, :value])
    :ok = :mnesia.wait_for_tables([tab], 5_000)
    :ok
  end

  def write(db, table, key, value) do
    tab = table_name(db, table)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({tab, key, value}) end)
    :ok
  end

  def read(db, table, key) do
    tab = table_name(db, table)

    {:atomic, result} = :mnesia.transaction(fn -> :mnesia.read(tab, key) end)

    case result do
      [{^tab, ^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  def delete(db, table, key) do
    tab = table_name(db, table)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.delete({tab, key}) end)
    :ok
  end

  def scan(db, table, from, to) do
    tab = table_name(db, table)

    match_spec = [
      {{tab, :"$1", :"$2"}, [{:>=, :"$1", from}, {:"=<", :"$1", to}], [{{:"$1", :"$2"}}]}
    ]

    {:atomic, result} = :mnesia.transaction(fn -> :mnesia.select(tab, match_spec) end)
    Enum.sort_by(result, fn {k, _v} -> k end)
  end
end
