defmodule Unex.Storage.Database do
  @moduledoc """
  Database namespace management for Unex storage.
  A database is a logical namespace registered in the Mnesia registry table.
  """

  @registry :unex_registry

  def create(name) do
    :mnesia.transaction(fn ->
      :mnesia.write({@registry, {:database, name}, true})
    end)

    :ok
  end

  def exists?(name) do
    case :mnesia.transaction(fn -> :mnesia.read(@registry, {:database, name}) end) do
      {:atomic, [_]} -> true
      _ -> false
    end
  end

  def list do
    {:atomic, records} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@registry, {:database, :_}, :_})
      end)

    Enum.map(records, fn {@registry, {:database, name}, _} -> name end)
  end
end
