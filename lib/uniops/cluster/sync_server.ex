defmodule Uniops.Cluster.SyncServer do
  @moduledoc """
  GenServer that serves hash requests from remote peers and resolves missing
  hashes by asking connected cluster nodes.
  """

  use GenServer

  alias Uniops.Cluster.HashCache

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Starts the sync server. `cache:` defaults to `HashCache`, `name:` defaults to `#{__MODULE__}`."
  def start_link(opts \\ []) do
    cache = Keyword.get(opts, :cache, HashCache)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{cache: cache}, name: name)
  end

  @doc "Returns `{:ok, data}` or `:not_found` from the local cache."
  def fetch_local(server \\ __MODULE__, hash) do
    GenServer.call(server, {:fetch_local, hash})
  end

  @doc """
  Resolves a list of hashes. Checks local cache for each; for missing ones,
  asks connected peer nodes. Caches anything received from peers.

  Returns `{:ok, %{hash => data}}` if all resolved, or
  `{:error, {:missing, [hash]}}` if any remain unresolvable.
  """
  def resolve(server \\ __MODULE__, hashes) when is_list(hashes) do
    GenServer.call(server, {:resolve, hashes}, :infinity)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch_local, hash}, _from, state) do
    result = HashCache.get(state.cache, hash)
    {:reply, result, state}
  end

  def handle_call({:resolve, hashes}, _from, state) do
    # Split into found/missing from local cache
    {found, missing} =
      Enum.reduce(hashes, {%{}, []}, fn hash, {acc_found, acc_missing} ->
        case HashCache.get(state.cache, hash) do
          {:ok, data} -> {Map.put(acc_found, hash, data), acc_missing}
          :not_found -> {acc_found, [hash | acc_missing]}
        end
      end)

    # Try to resolve missing from peers
    {peer_found, still_missing} = fetch_from_peers(missing, state)

    # Cache anything retrieved from peers
    Enum.each(peer_found, fn {hash, data} ->
      HashCache.put(state.cache, hash, data)
    end)

    all_found = Map.merge(found, peer_found)

    result =
      if still_missing == [] do
        {:ok, all_found}
      else
        {:error, {:missing, still_missing}}
      end

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_from_peers(missing, _state) do
    peers = Node.list()

    Enum.reduce(missing, {%{}, []}, fn hash, {found, still_missing} ->
      case ask_peers(peers, hash) do
        {:ok, data} -> {Map.put(found, hash, data), still_missing}
        :not_found -> {found, [hash | still_missing]}
      end
    end)
  end

  defp ask_peers([], _hash), do: :not_found

  defp ask_peers([peer | rest], hash) do
    try do
      case GenServer.call({__MODULE__, peer}, {:fetch_local, hash}, 5_000) do
        {:ok, data} -> {:ok, data}
        :not_found -> ask_peers(rest, hash)
      end
    catch
      :exit, _ -> ask_peers(rest, hash)
    end
  end
end
