defmodule Unex.Cluster.HashCache do
  @moduledoc """
  ETS-backed cache for Unison bytecode blobs, keyed by SHA256 hex string.

  Reads go directly to ETS (no GenServer round-trip); writes go through
  the GenServer so that only one process owns the table.
  """

  use GenServer

  @type hash :: String.t()

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Starts the cache. `name:` defaults to `#{__MODULE__}`."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  Two-argument form: computes SHA256 of `data`, stores it, returns the hex
  hash string. `server` defaults to `#{__MODULE__}`.
  """
  def put(server \\ __MODULE__, data) when is_binary(data) do
    hash = hash_of(data)
    :ok = GenServer.call(server, {:put, hash, data})
    hash
  end

  @doc """
  Three-argument form: stores `data` under the given explicit `hash`.
  Returns `:ok`. Always requires an explicit `server` argument.
  """
  def put(server, hash, data) when is_binary(hash) and is_binary(data) do
    GenServer.call(server, {:put, hash, data})
  end

  @doc "Returns `{:ok, data}` or `:not_found`. Reads directly from ETS."
  def get(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, hash) do
      [{^hash, data}] -> {:ok, data}
      [] -> :not_found
    end
  end

  @doc "Returns `true` if `hash` is in the cache."
  def has?(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)
    :ets.member(table, hash)
  end

  @doc "Returns the list of all hash strings stored in the cache."
  def list(server \\ __MODULE__) do
    table = GenServer.call(server, :table)
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc """
  Returns a map with `:count` and `:total_bytes` — cheap aggregate stats
  for monitoring/dashboards. Walks the ETS table once.
  """
  def stats(server \\ __MODULE__) do
    table = GenServer.call(server, :table)

    :ets.foldl(
      fn {_hash, data}, acc ->
        %{count: acc.count + 1, total_bytes: acc.total_bytes + byte_size(data)}
      end,
      %{count: 0, total_bytes: 0},
      table
    )
  end

  @doc "Computes the SHA256 hex string for `data` (lowercase)."
  def hash_of(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(name) do
    table = :ets.new(name, [:set, :public, {:read_concurrency, true}])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, hash, data}, _from, state) do
    :ets.insert(state.table, {hash, data})
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, state) do
    {:reply, state.table, state}
  end
end
