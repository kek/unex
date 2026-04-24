defmodule Unex.Cluster.PeerConnector do
  @moduledoc """
  Automatically connects to declared peer nodes with exponential backoff.
  Only started when BEAM distribution is enabled (UNEX_NODE is set).
  """

  use GenServer

  require Logger

  @default_interval 1_000
  @max_interval 30_000
  @recheck_interval 30_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current connection status."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Converts a list of string peer names to atoms."
  def parse_peers(peers) when is_list(peers) do
    Enum.map(peers, fn
      peer when is_atom(peer) -> peer
      peer when is_binary(peer) -> String.to_atom(peer)
    end)
  end

  @doc false
  def record_up(state, peer) do
    Unex.Dashboard.Events.broadcast_cluster({:node_up, peer})
    %{state | connected: MapSet.put(state.connected, peer)}
  end

  @impl true
  def init(opts) do
    peers = Keyword.get(opts, :peers, []) |> parse_peers()
    interval = Keyword.get(opts, :connect_interval, @default_interval)

    state = %{
      peers: peers,
      connected: MapSet.new(),
      backoffs: Map.new(peers, fn p -> {p, interval} end),
      base_interval: interval
    }

    if peers != [] do
      send(self(), :connect)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state = attempt_connections(state)
    schedule_recheck(state)
    {:noreply, state}
  end

  def handle_info({:retry, peer}, state) do
    state = try_connect(state, peer)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      peers: state.peers,
      connected: MapSet.to_list(state.connected),
      pending: state.peers -- MapSet.to_list(state.connected)
    }

    {:reply, status, state}
  end

  defp attempt_connections(state) do
    Enum.reduce(state.peers, state, fn peer, acc ->
      try_connect(acc, peer)
    end)
  end

  defp try_connect(state, peer) do
    if MapSet.member?(state.connected, peer) do
      state
    else
      case Node.connect(peer) do
        true ->
          Logger.info("[unex] Connected to peer #{peer}")
          record_up(state, peer)

        _ ->
          backoff = Map.get(state.backoffs, peer, state.base_interval)
          Logger.warning("[unex] Failed to connect to #{peer}, retrying in #{backoff}ms")
          Process.send_after(self(), {:retry, peer}, backoff)
          new_backoff = min(backoff * 2, @max_interval)
          %{state | backoffs: Map.put(state.backoffs, peer, new_backoff)}
      end
    end
  end

  defp schedule_recheck(state) do
    if state.peers != [] do
      Process.send_after(self(), :connect, @recheck_interval)
    end
  end
end
