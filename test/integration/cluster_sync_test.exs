defmodule Unex.Integration.ClusterSyncTest do
  use ExUnit.Case, async: false

  alias Unex.Cluster.HashCache
  alias Unex.Cluster.SyncServer

  @moduletag timeout: 60_000

  setup_all do
    # Ensure this node is distributed
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:unex_test, :shortnames])
    end

    :ok
  end

  setup do
    # Start a peer node with our code paths (keep as charlists for :peer)
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    {:ok, pid, peer_node} = :peer.start_link(%{name: :unex_peer1, args: pa_args})

    # Start required apps and GenServers on the peer.
    # Use GenServer.start (not start_link) so the process isn't linked to the
    # short-lived RPC caller process.
    {:ok, _} = :rpc.call(peer_node, Application, :ensure_all_started, [:crypto])
    {:ok, _} = :rpc.call(peer_node, GenServer, :start, [HashCache, HashCache, [name: HashCache]])
    {:ok, _} = :rpc.call(peer_node, GenServer, :start, [SyncServer, %{cache: HashCache}, [name: SyncServer]])

    on_exit(fn ->
      try do
        :peer.stop(pid)
      catch
        _, _ -> :ok
      end
    end)

    %{peer: peer_node}
  end

  test "hash on local node syncs to peer via resolve", %{peer: peer} do
    data = "local-bytecode-blob-#{System.unique_integer([:positive])}"
    hash = HashCache.put(data)

    # Peer doesn't have it yet
    assert :not_found = :rpc.call(peer, HashCache, :get, [HashCache, hash])

    # Peer resolves the hash (fetches from us)
    assert {:ok, result} = :rpc.call(peer, SyncServer, :resolve, [SyncServer, [hash]])
    assert result[hash] == data

    # Peer now has it cached locally
    assert {:ok, ^data} = :rpc.call(peer, HashCache, :get, [HashCache, hash])
  end

  test "resolve missing hash returns error", %{peer: peer} do
    missing = "0000000000000000000000000000000000000000000000000000000000000000"

    assert {:error, {:missing, missing_list}} =
             :rpc.call(peer, SyncServer, :resolve, [SyncServer, [missing]])

    assert missing in missing_list
  end

  test "hash on peer syncs to local via resolve", %{peer: peer} do
    data = "peer-bytecode-blob-#{System.unique_integer([:positive])}"
    hash = :rpc.call(peer, HashCache, :put, [HashCache, data])

    # Local doesn't have it
    assert :not_found = HashCache.get(hash)

    # Local resolves (fetches from peer)
    assert {:ok, result} = SyncServer.resolve([hash])
    assert result[hash] == data

    # Local now has it cached
    assert {:ok, ^data} = HashCache.get(hash)
  end
end
