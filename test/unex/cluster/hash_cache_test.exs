defmodule Unex.Cluster.HashCacheTest do
  use ExUnit.Case, async: true

  alias Unex.Cluster.HashCache

  setup do
    name = :"hash_cache_#{System.unique_integer([:positive])}"
    cache = start_supervised!({HashCache, name: name})
    %{cache: cache, name: name}
  end

  test "put/2 stores data and get/2 retrieves it", %{cache: cache} do
    data = "hello world"
    hash = HashCache.put(cache, data)
    assert {:ok, ^data} = HashCache.get(cache, hash)
  end

  test "get/2 returns :not_found for unknown hash", %{cache: cache} do
    assert :not_found = HashCache.get(cache, "deadbeef")
  end

  test "put/3 with explicit hash stores and retrieves correctly", %{cache: cache} do
    hash = "abc123"
    data = "explicit"
    assert :ok = HashCache.put(cache, hash, data)
    assert {:ok, ^data} = HashCache.get(cache, hash)
  end

  test "has?/2 returns false for missing hash", %{cache: cache} do
    refute HashCache.has?(cache, "missing")
  end

  test "has?/2 returns true for stored hash", %{cache: cache} do
    data = "present"
    hash = HashCache.put(cache, data)
    assert HashCache.has?(cache, hash)
  end

  test "list/1 returns empty list when cache is empty", %{cache: cache} do
    assert [] = HashCache.list(cache)
  end

  test "list/1 returns all stored hashes", %{cache: cache} do
    h1 = HashCache.put(cache, "foo")
    h2 = HashCache.put(cache, "bar")
    listed = HashCache.list(cache)
    assert length(listed) == 2
    assert h1 in listed
    assert h2 in listed
  end

  test "hash_of/1 computes correct SHA256 hex" do
    # echo -n "hello" | sha256sum
    expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    assert HashCache.hash_of("hello") == expected
  end

  describe "stats/1" do
    test "returns count 0 and total_bytes 0 for empty cache", %{cache: cache} do
      assert %{count: 0, total_bytes: 0} = HashCache.stats(cache)
    end

    test "returns count and total bytes after puts", %{cache: cache} do
      _h1 = HashCache.put(cache, "hello")
      _h2 = HashCache.put(cache, "world!!")
      stats = HashCache.stats(cache)
      assert stats.count == 2
      assert stats.total_bytes == byte_size("hello") + byte_size("world!!")
    end
  end
end
