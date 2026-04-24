defmodule Unex.Cluster.DepsCacheTest do
  use ExUnit.Case, async: true

  alias Unex.Cluster.DepsCache

  setup do
    name = :"deps_#{System.unique_integer([:positive])}"
    start_supervised!({DepsCache, name: name})
    %{cache: name}
  end

  test "get returns :not_found initially", %{cache: c} do
    assert DepsCache.get(c, "abc") == :not_found
  end

  test "put then get", %{cache: c} do
    :ok = DepsCache.put(c, "abc", ["def", "ghi"])
    assert {:ok, ["def", "ghi"]} = DepsCache.get(c, "abc")
  end

  test "referrers scans the table", %{cache: c} do
    :ok = DepsCache.put(c, "a", ["shared"])
    :ok = DepsCache.put(c, "b", ["shared", "other"])
    :ok = DepsCache.put(c, "c", ["other"])

    referrers = DepsCache.referrers(c, "shared")
    assert Enum.sort(referrers) == ["a", "b"]
  end

  test "put overwrites prior value", %{cache: c} do
    :ok = DepsCache.put(c, "a", ["x"])
    :ok = DepsCache.put(c, "a", ["y", "z"])
    assert {:ok, ["y", "z"]} = DepsCache.get(c, "a")
  end
end
