defmodule Unex.Integration.ServicesClusterTest do
  use ExUnit.Case, async: false

  alias Unex.Cluster.HashCache
  alias Unex.Cluster.SyncServer
  alias Unex.Services
  alias Unex.Services.Registry

  @moduletag timeout: 300_000
  @moduletag :integration

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:unex_svc_test, :shortnames])
    end

    :ok
  end

  setup do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    {:ok, pid, peer} = :peer.start_link(%{name: :svc_peer, args: pa_args})

    {:ok, _} = :rpc.call(peer, Application, :ensure_all_started, [:crypto])
    # Registry.init/1 receives a single name atom (not a keyword list)
    {:ok, _} = :rpc.call(peer, GenServer, :start, [HashCache, HashCache, [name: HashCache]])
    {:ok, _} = :rpc.call(peer, GenServer, :start, [SyncServer, %{cache: HashCache}, [name: SyncServer]])
    {:ok, _} = :rpc.call(peer, GenServer, :start, [Registry, Registry, [name: Registry]])

    on_exit(fn ->
      try do
        :peer.stop(pid)
      catch
        _, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  test "release on local, call from peer by name", %{peer: peer} do
    hash = HashCache.put("cross-node-fake-bytecode-#{System.unique_integer()}")
    {:ok, entry} = Services.release("remote_greeter", hash)
    assert entry.name == "remote_greeter"
    assert entry.node == node()

    # Peer resolves via Registry (asks peers)
    assert {:ok, resolved} = :rpc.call(peer, Registry, :resolve, ["remote_greeter"])
    assert resolved.hash == hash
  end

  test "peer resolve finds service registered on local node", %{peer: peer} do
    hash = HashCache.put("resolve-check-fake-bytecode-#{System.unique_integer()}")
    {:ok, entry} = Services.release("resolve_target", hash)

    # Peer's local lookup should not find it
    assert :not_found = :rpc.call(peer, Registry, :lookup, [Registry, "resolve_target"])

    # But peer's resolve should find it by asking peers
    assert {:ok, resolved} = :rpc.call(peer, Registry, :resolve, [Registry, "resolve_target"])
    assert resolved.name == entry.name
    assert resolved.hash == entry.hash
  end
end
