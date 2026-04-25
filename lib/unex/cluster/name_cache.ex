defmodule Unex.Cluster.NameCache do
  @moduledoc """
  ETS-backed cache of Unison term names keyed by hash. Populated at
  deploy time from the name → hash map produced by the extractor.

  Used by the dashboard to label hashes (e.g. `Unex.main` next to a
  16-char hash prefix in dep lists).
  """

  use GenServer

  @type hash :: String.t()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Stores `name` under `hash`. Returns `:ok`."
  def put(server \\ __MODULE__, hash, name)
      when is_binary(hash) and is_binary(name) do
    GenServer.call(server, {:put, hash, name})
  end

  @doc "Returns `{:ok, name}` or `:not_found`. Reads directly from ETS."
  def get(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, hash) do
      [{^hash, name}] -> {:ok, name}
      [] -> :not_found
    end
  end

  @doc "Clears the cache. Used by integration tests that re-deploy."
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @impl true
  def init(name) do
    table = :ets.new(name, [:set, :protected, {:read_concurrency, true}])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, hash, name}, _from, state) do
    :ets.insert(state.table, {hash, name})
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, state), do: {:reply, state.table, state}
end
