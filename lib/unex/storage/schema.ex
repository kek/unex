defmodule Unex.Storage.Schema do
  @moduledoc """
  Initializes Mnesia schema and core tables for Unex storage.
  """

  @registry_table :unex_registry
  @services_table :unex_services

  def services_table, do: @services_table

  def init(dir) do
    File.mkdir_p!(dir)
    :mnesia.stop()
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))

    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
      other -> raise "mnesia create_schema failed: #{inspect(other)}"
    end

    :ok = :mnesia.start()

    ensure_table!(@registry_table, attributes: [:key, :value])
    ensure_table!(@services_table, attributes: [:name, :entry])

    :ok = :mnesia.wait_for_tables([@registry_table, @services_table], 5_000)
    :ok
  end

  @doc false
  def ensure_table!(name, opts) do
    opts = Keyword.merge([disc_copies: [node()]], opts)

    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^name}} ->
        :ok

      {:aborted, reason} ->
        raise "mnesia create_table #{inspect(name)} failed: #{inspect(reason)}"
    end
  end
end
