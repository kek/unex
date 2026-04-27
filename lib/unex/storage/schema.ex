defmodule Unex.Storage.Schema do
  @moduledoc """
  Initializes Mnesia schema and core tables for Unex storage.
  """

  @registry_table :unex_registry
  @services_table :unex_services

  def services_table, do: @services_table

  def init(dir) do
    :mnesia.stop()
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))
    :mnesia.create_schema([node()])
    :mnesia.start()

    :mnesia.create_table(@registry_table,
      disc_copies: [node()],
      attributes: [:key, :value]
    )

    :mnesia.create_table(@services_table,
      disc_copies: [node()],
      attributes: [:name, :entry]
    )

    :mnesia.wait_for_tables([@registry_table, @services_table], 5_000)
    :ok
  end
end
