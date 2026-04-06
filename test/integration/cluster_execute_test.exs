defmodule Unex.Integration.ClusterExecuteTest do
  use ExUnit.Case, async: false

  alias Unex.Cluster.HashCache
  alias Unex.Cluster.SyncServer

  @moduletag timeout: 300_000

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:unex_test, :shortnames])
    end

    :ok
  end

  setup do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    {:ok, pid, peer_node} = :peer.start_link(%{name: :unex_exec_peer, args: pa_args})

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

  test "compile, cache, sync to peer, and execute bytecode", %{peer: peer} do
    # 1. Compile a simple Unison program
    source = "main : '{IO, Exception} ()\nmain = do printLine \"synced-and-executed\""

    dir =
      Path.join(
        System.tmp_dir!(),
        "unex_cluster_exec_#{System.unique_integer([:positive])}"
      )

    {:ok, workspace} = Unex.Workspace.create(dir)
    {:ok, file_path} = Unex.Workspace.write_source(workspace, "program.u", source)
    {:ok, uc_path} = Unex.Compiler.compile(workspace, file_path, "main", "program")

    # 2. Cache the .uc bytes locally
    uc_bytes = File.read!(uc_path)
    hash = HashCache.put(uc_bytes)

    # 3. Peer resolves the hash (fetches bytecode from us)
    assert {:ok, _resolved} = :rpc.call(peer, SyncServer, :resolve, [SyncServer, [hash]])

    # 4. Get synced bytes from peer, write to temp file, execute
    {:ok, synced_bytes} = :rpc.call(peer, HashCache, :get, [HashCache, hash])
    assert synced_bytes == uc_bytes

    peer_uc_path = Path.join(System.tmp_dir!(), "synced_#{hash}.uc")
    File.write!(peer_uc_path, synced_bytes)

    {:ok, result} = Unex.Runner.run_compiled(peer_uc_path)
    assert result.stdout =~ "synced-and-executed"

    # 5. Cleanup
    File.rm(peer_uc_path)
    Unex.Workspace.destroy(workspace)
  end
end
