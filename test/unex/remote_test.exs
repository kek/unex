defmodule Unex.RemoteTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  setup do
    {:ok, _} = Unex.Cluster.HashCache.start_link(name: :remote_test_cache)
    {:ok, _} = Unex.Cluster.SyncServer.start_link(cache: :remote_test_cache, name: :remote_test_sync)

    on_exit(fn ->
      for name <- [:remote_test_cache, :remote_test_sync] do
        if pid = Process.whereis(name), do: GenServer.stop(pid)
      end
    end)

    :ok
  end

  test "execute with unknown hash returns error" do
    assert {:error, _} = Unex.Remote.execute("nonexistent_hash_abc123")
  end
end
