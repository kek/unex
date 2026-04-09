defmodule Unex.ServicesTest do
  use ExUnit.Case, async: false

  alias Unex.Services
  alias Unex.Services.Registry.Entry
  alias Unex.Cluster.HashCache

  @moduletag timeout: 120_000

  test "release registers name and resolves to correct hash" do
    hash = HashCache.put("fake_bytes_#{System.unique_integer()}")
    {:ok, %Entry{name: "rel-test", hash: ^hash}} = Services.release("rel-test", hash)
    assert {:ok, %Entry{name: "rel-test", hash: ^hash}} =
             Unex.Services.Registry.resolve("rel-test")
  end

  test "call unknown service returns not_found" do
    assert {:error, :not_found} = Services.call("no-such-service-xyz")
  end

  test "list includes released service" do
    hash = HashCache.put("listed_bytes_#{System.unique_integer()}")
    Services.release("listed-svc-test", hash)
    names = Services.list() |> Enum.map(& &1.name)
    assert "listed-svc-test" in names
  end

  test "undeploy then call returns not_found" do
    hash = HashCache.put("temp_bytes_#{System.unique_integer()}")
    Services.release("temp-svc-test", hash)
    :ok = Services.undeploy("temp-svc-test")
    assert {:error, :not_found} = Services.call("temp-svc-test")
  end
end
