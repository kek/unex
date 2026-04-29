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

    case :mnesia.wait_for_tables([@registry_table, @services_table], 5_000) do
      :ok -> :ok
      {:timeout, tables} -> raise_load_timeout!(tables, dir)
      {:error, reason} -> raise "mnesia.wait_for_tables failed: #{inspect(reason)}"
    end

    :ok
  end

  defp raise_load_timeout!(tables, dir) do
    current_node = node()

    details =
      Enum.map_join(tables, "\n", fn tab ->
        owners =
          try do
            :mnesia.table_info(tab, :disc_copies)
          rescue
            _ -> :unknown
          end

        "  - #{inspect(tab)}: disc_copies=#{inspect(owners)}"
      end)

    raise """
    Mnesia tables failed to load within 5s. Current node: #{inspect(current_node)}.

    Tables stuck loading:
    #{details}

    If a listed disc_copies node differs from the current node, the BEAM is
    booting with a different name than when the data was created. This is
    common in containers with rotating hostnames (e.g. podman container IDs).
    Fix one of:
      * Set UNEX_NODE to the original node name (and UNEX_COOKIE).
      * Set RELEASE_DISTRIBUTION=none so the node is always nonode@nohost.
      * Wipe the data directory to start fresh: rm -rf #{dir}
    """
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
