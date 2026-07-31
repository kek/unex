defmodule Unex.ServicesReleaseTest do
  use ExUnit.Case, async: false

  alias Unex.Services
  alias Unex.Services.Registry
  alias Unex.Cluster.HashCache

  @moduletag timeout: 120_000

  test "release points a name at an existing hash" do
    hash = HashCache.put("release_v1_#{System.unique_integer()}")

    assert {:ok, entry} = Services.release("rel-svc", hash)
    assert entry.hash == hash

    {:ok, resolved} = Registry.resolve("rel-svc")
    assert resolved.hash == hash
  end

  test "release can point a name at a different existing hash" do
    hash_v1 = HashCache.put("rollback_v1_#{System.unique_integer()}")
    hash_v2 = HashCache.put("rollback_v2_#{System.unique_integer()}")

    {:ok, _} = Services.release("rollback-app", hash_v2)
    {:ok, resolved} = Registry.resolve("rollback-app")
    assert resolved.hash == hash_v2

    {:ok, _} = Services.release("rollback-app", hash_v1)
    {:ok, resolved} = Registry.resolve("rollback-app")
    assert resolved.hash == hash_v1
  end

  test "release on unknown hash still registers the name" do
    assert {:ok, entry} = Services.release("ghost-svc", "nonexistent-hash-abc")
    assert entry.hash == "nonexistent-hash-abc"
    {:ok, resolved} = Registry.resolve("ghost-svc")
    assert resolved.hash == "nonexistent-hash-abc"
  end

  describe "provenance across releases" do
    test "a bare release keeps the project and entry point of the last deploy" do
      h1 = HashCache.put("prov_v1_#{System.unique_integer()}")
      h2 = HashCache.put("prov_v2_#{System.unique_integer()}")

      {:ok, _} =
        Services.release("prov-svc", h1, project: "@kek/counter", entry_point: "mainCounter")

      {:ok, entry} = Services.release("prov-svc", h2)

      assert entry.project == "@kek/counter"
      assert entry.entry_point == "mainCounter"
    end

    # A local-file deploy has no `ucm pull` argument, so it records
    # `project: nil` on purpose. Inheriting the previous Share project there
    # would make the dashboard link a local build to somebody else's Share page,
    # so an explicitly-passed nil has to win over the merge.
    test "an explicit nil project clears a stale Share link" do
      h1 = HashCache.put("prov_share_#{System.unique_integer()}")
      h2 = HashCache.put("prov_local_#{System.unique_integer()}")

      {:ok, _} =
        Services.release("prov-local", h1, project: "@kek/counter", entry_point: "mainCounter")

      {:ok, entry} =
        Services.release("prov-local", h2, project: nil, entry_point: "mainCounter")

      assert entry.project == nil
      assert entry.entry_point == "mainCounter"
    end
  end
end
