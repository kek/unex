defmodule Unex.Integration.RemoteExecuteTest do
  use ExUnit.Case, async: false

  alias Unex.Cluster.HashCache
  alias Unex.Cluster.SyncServer
  alias Unex.Remote

  @moduletag timeout: 300_000

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:unex_remote_test, :shortnames])
    end

    :ok
  end

  setup do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    {:ok, pid, peer_node} = :peer.start_link(%{name: :remote_exec_peer, args: pa_args})

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

  defp compile_and_cache(message) do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"#{message}\""
    dir = Path.join(System.tmp_dir!(), "unex_remote_exec_#{System.unique_integer([:positive])}")
    {:ok, workspace} = Unex.Workspace.create(dir)
    {:ok, file_path} = Unex.Workspace.write_source(workspace, "program.u", source)
    {:ok, uc_path} = Unex.Compiler.compile(workspace, file_path, "main", "program")
    uc_bytes = File.read!(uc_path)
    hash = HashCache.put(uc_bytes)
    {hash, workspace}
  end

  test "execute on peer node", %{peer: peer} do
    {hash, workspace} = compile_and_cache("executed-on-peer")

    try do
      assert {:ok, result} = Remote.execute(hash, node: peer, timeout: 120_000)
      assert result.stdout =~ "executed-on-peer"
    after
      Unex.Workspace.destroy(workspace)
    end
  end

  test "submit picks peer node", %{peer: _peer} do
    {hash, workspace} = compile_and_cache("submitted-ok")

    try do
      # peer is the only connected node, so submit must pick it
      assert {:ok, result} = Remote.submit(hash, timeout: 120_000)
      assert result.stdout =~ "submitted-ok"
    after
      Unex.Workspace.destroy(workspace)
    end
  end

  test "error on unreachable node" do
    fake_hash = HashCache.hash_of("does-not-matter")
    assert {:error, {:rpc_failed, :nonexistent@nohost, _reason}} =
             Remote.execute(fake_hash, node: :nonexistent@nohost, timeout: 5_000)
  end
end
