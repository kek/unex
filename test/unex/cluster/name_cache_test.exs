defmodule Unex.Cluster.NameCacheTest do
  use ExUnit.Case, async: true

  alias Unex.Cluster.NameCache

  setup do
    name = :"name_cache_#{System.unique_integer([:positive])}"
    cache = start_supervised!({NameCache, name: name})
    %{cache: cache}
  end

  test "get returns :not_found for unknown hash", %{cache: c} do
    assert :not_found = NameCache.get(c, "deadbeef")
  end

  test "put then get round-trips", %{cache: c} do
    hash = "abc123"
    label = "Unex.main"
    assert :ok = NameCache.put(c, hash, label)
    assert {:ok, ^label} = NameCache.get(c, hash)
  end

  test "put overwrites previous value", %{cache: c} do
    hash = "abc123"
    assert :ok = NameCache.put(c, hash, "old")
    assert :ok = NameCache.put(c, hash, "new")
    assert {:ok, "new"} = NameCache.get(c, hash)
  end

  test "clear removes all entries", %{cache: c} do
    :ok = NameCache.put(c, "a", "first")
    :ok = NameCache.put(c, "b", "second")
    :ok = NameCache.clear(c)
    assert :not_found = NameCache.get(c, "a")
    assert :not_found = NameCache.get(c, "b")
  end
end
