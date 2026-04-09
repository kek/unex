defmodule Unex.ServicesReleaseTest do
  use ExUnit.Case, async: false

  alias Unex.Services
  alias Unex.Services.Registry

  @moduletag timeout: 120_000

  test "release points a name at an existing hash" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"v1\""
    {:ok, entry} = Services.deploy("rel-svc", source)
    original_hash = entry.hash

    assert :ok = Services.release("rel-svc", original_hash)

    {:ok, resolved} = Registry.resolve("rel-svc")
    assert resolved.hash == original_hash
  end

  test "release can point a name at a different existing hash" do
    source_v1 = "main : '{IO, Exception} ()\nmain = do printLine \"v1\""
    source_v2 = "main : '{IO, Exception} ()\nmain = do printLine \"v2\""

    {:ok, entry_v1} = Services.deploy("rollback-svc-v1", source_v1)
    {:ok, entry_v2} = Services.deploy("rollback-svc-v2", source_v2)

    :ok = Services.release("my-app", entry_v2.hash)
    {:ok, result} = Services.call("my-app")
    assert result.stdout =~ "v2"

    :ok = Services.release("my-app", entry_v1.hash)
    {:ok, result} = Services.call("my-app")
    assert result.stdout =~ "v1"
  end

  test "release on unknown hash still registers the name" do
    assert :ok = Services.release("ghost-svc", "nonexistent-hash-abc")
    {:ok, resolved} = Registry.resolve("ghost-svc")
    assert resolved.hash == "nonexistent-hash-abc"
  end
end
