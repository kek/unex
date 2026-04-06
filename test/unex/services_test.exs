defmodule Unex.ServicesTest do
  use ExUnit.Case, async: false

  alias Unex.Services
  alias Unex.Services.Registry.Entry

  @moduletag timeout: 180_000

  test "deploy and call a service" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"svc-hello\""
    assert {:ok, %Entry{name: "hello-svc"}} = Services.deploy("hello-svc", source)

    assert {:ok, result} = Services.call("hello-svc")
    assert result.stdout =~ "svc-hello"
  end

  test "redeploy updates hash and call returns new output" do
    source_v1 = "main : '{IO, Exception} ()\nmain = do printLine \"version-1\""
    source_v2 = "main : '{IO, Exception} ()\nmain = do printLine \"version-2\""

    assert {:ok, %Entry{hash: hash1}} = Services.deploy("redeploy-svc", source_v1)
    assert {:ok, %Entry{hash: hash2}} = Services.deploy("redeploy-svc", source_v2)
    assert hash1 != hash2

    assert {:ok, result} = Services.call("redeploy-svc")
    assert result.stdout =~ "version-2"
  end

  test "call unknown service returns not_found" do
    assert {:error, :not_found} = Services.call("no-such-service")
  end

  test "list includes deployed service" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"listed\""
    {:ok, _} = Services.deploy("listed-svc", source)

    entries = Services.list()
    names = Enum.map(entries, & &1.name)
    assert "listed-svc" in names
  end

  test "undeploy then call returns not_found" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"bye\""
    {:ok, _} = Services.deploy("temp-svc", source)
    :ok = Services.undeploy("temp-svc")

    assert {:error, :not_found} = Services.call("temp-svc")
  end
end
