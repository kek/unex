defmodule Uniops.Cluster.SyncServerTest do
  use ExUnit.Case, async: true

  alias Uniops.Cluster.HashCache
  alias Uniops.Cluster.SyncServer

  setup do
    suffix = System.unique_integer([:positive])
    cache_name = :"sync_cache_#{suffix}"
    server_name = :"sync_server_#{suffix}"

    start_supervised!({HashCache, name: cache_name})
    start_supervised!({SyncServer, cache: cache_name, name: server_name})

    %{cache: cache_name, server: server_name}
  end

  test "fetch_local returns data from local cache", %{cache: cache, server: server} do
    data = "bytecode blob"
    hash = HashCache.put(cache, data)

    assert {:ok, ^data} = SyncServer.fetch_local(server, hash)
  end

  test "fetch_local returns :not_found for missing hash", %{server: server} do
    assert :not_found = SyncServer.fetch_local(server, "nonexistent")
  end

  test "resolve succeeds for locally available hashes", %{cache: cache, server: server} do
    data1 = "first blob"
    data2 = "second blob"
    h1 = HashCache.put(cache, data1)
    h2 = HashCache.put(cache, data2)

    assert {:ok, result} = SyncServer.resolve(server, [h1, h2])
    assert result[h1] == data1
    assert result[h2] == data2
  end

  test "resolve returns {:error, {:missing, [...]}} for unavailable hashes", %{server: server} do
    missing_hash = "deadbeefdeadbeefdeadbeef"
    assert {:error, {:missing, missing}} = SyncServer.resolve(server, [missing_hash])
    assert missing_hash in missing
  end
end
