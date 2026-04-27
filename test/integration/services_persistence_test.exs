defmodule Unex.Integration.ServicesPersistenceTest do
  @moduledoc """
  Verifies that deployed services survive a process restart by re-hydrating
  the registry from Mnesia and the hash cache from its on-disk directory.

  This test does not exercise Unison/UCM — it asserts the persistence
  contract for the two stores that hold service state.
  """

  use ExUnit.Case, async: false

  alias Unex.Cluster.HashCache
  alias Unex.Services.Registry
  alias Unex.Services.Registry.Entry
  alias Unex.Storage.Schema

  setup do
    suffix = :erlang.unique_integer([:positive])
    mnesia_dir = Path.join(System.tmp_dir!(), "unex_persist_test_mnesia_#{suffix}")
    cache_dir = Path.join(System.tmp_dir!(), "unex_persist_test_cache_#{suffix}")
    File.mkdir_p!(mnesia_dir)
    File.mkdir_p!(cache_dir)

    Schema.init(mnesia_dir)

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(mnesia_dir)
      File.rm_rf!(cache_dir)
    end)

    %{
      mnesia_dir: mnesia_dir,
      cache_dir: cache_dir,
      registry_name: :"persist_registry_#{suffix}",
      cache_name: :"persist_cache_#{suffix}"
    }
  end

  test "registry rehydrates from Mnesia after restart", %{registry_name: rname} do
    {:ok, pid1} = Registry.start_link(name: rname, persist?: true)

    {:ok, %Entry{}} =
      Registry.register(rname, "alpha", "abc123", node(),
        project: "@k/proj",
        entry_point: "main"
      )

    {:ok, %Entry{}} = Registry.register(rname, "beta", "def456", node())

    GenServer.stop(pid1)

    {:ok, _pid2} = Registry.start_link(name: rname, persist?: true)

    assert {:ok, %Entry{name: "alpha", hash: "abc123", project: "@k/proj", entry_point: "main"}} =
             Registry.lookup(rname, "alpha")

    assert {:ok, %Entry{name: "beta", hash: "def456"}} = Registry.lookup(rname, "beta")

    names = Registry.list(rname) |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["alpha", "beta"]
  end

  test "registry unregister persists the deletion", %{registry_name: rname} do
    {:ok, pid1} = Registry.start_link(name: rname, persist?: true)
    Registry.register(rname, "ephemeral", "h", node())
    :ok = Registry.unregister(rname, "ephemeral")
    GenServer.stop(pid1)

    {:ok, _pid2} = Registry.start_link(name: rname, persist?: true)
    assert :not_found = Registry.lookup(rname, "ephemeral")
  end

  test "hash cache rehydrates blobs from disk after restart", %{
    cache_dir: dir,
    cache_name: cname
  } do
    {:ok, pid1} = HashCache.start_link(name: cname, dir: dir)

    # SHA256-style root value
    h1 = HashCache.put(cname, "root-value-bytes")

    # SHA256-style explicit hash
    sha = "deadbeef" <> String.duplicate("0", 56)
    :ok = HashCache.put(cname, sha, "code-sha256")

    # Unison Link.Term style hash (lowercase base32, ~52 chars)
    unison_hash = "000tfpmgitersa5tj61brlf0spqaqfp0q75517b4ns9j0odfkejs4"
    :ok = HashCache.put(cname, unison_hash, "code-unison")

    GenServer.stop(pid1)

    {:ok, _pid2} = HashCache.start_link(name: cname, dir: dir)

    assert {:ok, "root-value-bytes"} = HashCache.get(cname, h1)
    assert {:ok, "code-sha256"} = HashCache.get(cname, sha)
    assert {:ok, "code-unison"} = HashCache.get(cname, unison_hash)

    %{count: count} = HashCache.stats(cname)
    assert count == 3
  end

  test "hash cache ignores stray non-hash files in dir on hydrate", %{
    cache_dir: dir,
    cache_name: cname
  } do
    File.write!(Path.join(dir, "README"), "not a blob")
    File.write!(Path.join(dir, "abc"), "too-short")
    File.write!(Path.join(dir, "blob.tmp"), "interrupted write")

    {:ok, _pid} = HashCache.start_link(name: cname, dir: dir)
    assert HashCache.list(cname) == []
  end
end
