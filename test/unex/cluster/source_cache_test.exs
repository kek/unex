defmodule Unex.Cluster.SourceCacheTest do
  use ExUnit.Case, async: true

  alias Unex.Cluster.SourceCache

  setup do
    name = :"source_cache_#{System.unique_integer([:positive])}"
    cache = start_supervised!({SourceCache, name: name})
    %{cache: cache}
  end

  test "get/2 returns :not_found for unknown hash", %{cache: cache} do
    assert :not_found = SourceCache.get(cache, "deadbeef")
  end

  test "put/3 stores source and get/2 retrieves it", %{cache: cache} do
    hash = "abc123"
    source = "myService : '{IO, Exception} ()\nmyService = do printLine \"hi\"\n"
    assert :ok = SourceCache.put(cache, hash, source)
    assert {:ok, ^source} = SourceCache.get(cache, hash)
  end

  test "put/3 overwrites previous source for same hash", %{cache: cache} do
    hash = "h1"
    assert :ok = SourceCache.put(cache, hash, "v1")
    assert :ok = SourceCache.put(cache, hash, "v2")
    assert {:ok, "v2"} = SourceCache.get(cache, hash)
  end

  test "keys/1 returns a MapSet of every cached hash", %{cache: cache} do
    assert SourceCache.keys(cache) == MapSet.new()
    :ok = SourceCache.put(cache, "h1", "src1")
    :ok = SourceCache.put(cache, "h2", "src2")
    assert SourceCache.keys(cache) == MapSet.new(["h1", "h2"])
  end
end
