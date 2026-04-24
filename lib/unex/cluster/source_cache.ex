defmodule Unex.Cluster.SourceCache do
  @moduledoc """
  ETS-backed cache of pretty-printed Unison source keyed by service
  root hash. Populated at deploy time by capturing UCM `view` output.
  """

  use GenServer

  @type hash :: String.t()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Stores `source` under `hash`. Returns `:ok`."
  def put(server \\ __MODULE__, hash, source)
      when is_binary(hash) and is_binary(source) do
    GenServer.call(server, {:put, hash, source})
  end

  @doc "Returns `{:ok, source}` or `:not_found`. Reads directly from ETS."
  def get(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, hash) do
      [{^hash, source}] -> {:ok, source}
      [] -> :not_found
    end
  end

  @impl true
  def init(name) do
    table = :ets.new(name, [:set, :protected, {:read_concurrency, true}])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, hash, source}, _from, state) do
    :ets.insert(state.table, {hash, source})
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, state), do: {:reply, state.table, state}
end
