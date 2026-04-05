defmodule Uniops.RemoteTest do
  use ExUnit.Case, async: false

  alias Uniops.Remote

  @moduletag timeout: 120_000

  setup do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"remote-ok\""
    dir = Path.join(System.tmp_dir!(), "uniops_remote_test_#{System.unique_integer([:positive])}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    {:ok, file_path} = Uniops.Workspace.write_source(workspace, "program.u", source)
    {:ok, uc_path} = Uniops.Compiler.compile(workspace, file_path, "main", "program")
    uc_bytes = File.read!(uc_path)
    hash = Uniops.Cluster.HashCache.put(uc_bytes)

    on_exit(fn -> Uniops.Workspace.destroy(workspace) end)

    %{hash: hash}
  end

  test "execute/2 runs bytecode locally", %{hash: hash} do
    assert {:ok, result} = Remote.execute(hash, timeout: 60_000)
    assert result.stdout =~ "remote-ok"
  end

  test "execute/2 returns error for unknown hash" do
    fake_hash = Uniops.Cluster.HashCache.hash_of("nonexistent")
    assert {:error, _} = Remote.execute(fake_hash)
  end
end
