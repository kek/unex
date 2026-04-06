defmodule Unex.Services.RegistryTest do
  use ExUnit.Case, async: true

  alias Unex.Services.Registry
  alias Unex.Services.Registry.Entry

  setup do
    registry = start_supervised!({Registry, name: :test_registry})
    %{registry: registry}
  end

  test "register and lookup return entry", %{registry: _} do
    assert {:ok, %Entry{name: "my-svc", hash: "abc123", node: :nonode@nohost}} =
             Registry.register(:test_registry, "my-svc", "abc123", :nonode@nohost)

    assert {:ok, %Entry{name: "my-svc", hash: "abc123"}} =
             Registry.lookup(:test_registry, "my-svc")
  end

  test "lookup returns not_found for unknown service", %{registry: _} do
    assert :not_found = Registry.lookup(:test_registry, "nonexistent")
  end

  test "redeploy updates hash", %{registry: _} do
    Registry.register(:test_registry, "svc", "hash_v1", :nonode@nohost)
    Registry.register(:test_registry, "svc", "hash_v2", :nonode@nohost)

    assert {:ok, %Entry{hash: "hash_v2"}} = Registry.lookup(:test_registry, "svc")
  end

  test "list returns all entries", %{registry: _} do
    Registry.register(:test_registry, "alpha", "h1", :nonode@nohost)
    Registry.register(:test_registry, "beta", "h2", :nonode@nohost)

    entries = Registry.list(:test_registry)
    names = Enum.map(entries, & &1.name) |> Enum.sort()
    assert names == ["alpha", "beta"]
  end

  test "unregister removes the service", %{registry: _} do
    Registry.register(:test_registry, "to-remove", "h1", :nonode@nohost)
    assert :ok = Registry.unregister(:test_registry, "to-remove")
    assert :not_found = Registry.lookup(:test_registry, "to-remove")
  end
end
