defmodule Unex.Cluster.DepsCache do
  @moduledoc """
  ETS-backed cache of dependency edges keyed by hash. Populated at
  deploy time from the extractor's per-term `.deps` output.

  Hashes are stored in the same normalized form as `HashCache` (no `#`
  prefix). Builtins (prefix `##`) appear in dep lists but aren't usually
  present in `HashCache` — consumers should handle missing-target
  gracefully.
  """

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Stores `hash -> [dep_hash, ...]`."
  def put(server \\ __MODULE__, hash, deps) when is_binary(hash) and is_list(deps) do
    GenServer.call(server, {:put, hash, deps})
  end

  @doc "Returns `{:ok, [dep_hash, ...]}` or `:not_found`."
  def get(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, hash) do
      [{^hash, deps}] -> {:ok, deps}
      [] -> :not_found
    end
  end

  @doc """
  Returns all hashes that list `hash` as a dependency (reverse edge).
  Full table scan — acceptable for typical service sizes.
  """
  def referrers(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)

    :ets.foldl(
      fn {src, deps}, acc ->
        if Enum.member?(deps, hash), do: [src | acc], else: acc
      end,
      [],
      table
    )
  end

  @impl true
  def init(name) do
    table = :ets.new(name, [:set, :public, {:read_concurrency, true}])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, hash, deps}, _from, state) do
    :ets.insert(state.table, {hash, deps})
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, state), do: {:reply, state.table, state}
end
