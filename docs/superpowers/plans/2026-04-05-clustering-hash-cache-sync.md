# BEAM Clustering, Hash Cache, and Dependency Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable multiple BEAM nodes to form a cluster, cache Unison bytecode by content hash in ETS, and sync missing bytecode between nodes on demand — the distribution infrastructure that Plan 4 (Remote handler) will build on.

**Architecture:** Each node runs a HashCache (ETS-backed GenServer storing bytecode keyed by SHA256) and a SyncServer (GenServer that serves hash requests from peers and pulls missing hashes from the cluster). Nodes connect via standard BEAM distribution (`Node.connect/1`). No external dependencies — clustering uses OTP's built-in distribution. Multi-node tests use OTP 25+'s `:peer` module to start ephemeral nodes.

**Tech Stack:** Elixir 1.19 / OTP 28, ETS (built-in), BEAM distribution (built-in), `:peer` module for testing

---

## Scope Note

This is Plan 3 of 6. It covers **only** the distribution infrastructure — no computation shipping yet. Plan 4 (Remote handler) will use these primitives to fork computations to other nodes.

What this plan delivers:
- ETS-backed hash cache for bytecode blobs
- Cluster membership awareness (connected peers)
- Cross-node hash sync protocol (request/serve)
- Proven multi-node test with bytecode sync between two BEAM nodes

What this plan does **not** cover:
- Remote code execution (Plan 4)
- Service registry (Plan 5)
- Mnesia replication across nodes (future optimization)
- Automatic node discovery via libcluster (can be added later — manual `Node.connect` suffices for now)

## Prerequisites

- Plans 1-2 completed
- OTP 28 (for `:peer` module in tests)

## File Structure

```
lib/
  uniops/
    application.ex                # Modify: add HashCache + SyncServer to supervision tree
    cluster/
      hash_cache.ex               # ETS-backed bytecode cache — store/get/has?/list by SHA256
      sync_server.ex              # GenServer: serves hashes to peers, pulls from peers on demand
test/
  uniops/
    cluster/
      hash_cache_test.exs         # Unit tests for local cache operations
      sync_server_test.exs        # Multi-node tests using :peer
  integration/
    cluster_sync_test.exs         # End-to-end: compile .uc, cache, sync to peer, run on peer
```

---

### Task 1: Hash Cache (ETS)

**Files:**
- Create: `lib/uniops/cluster/hash_cache.ex`
- Create: `test/uniops/cluster/hash_cache_test.exs`

The hash cache stores opaque bytecode blobs keyed by their SHA256 hash. It's a GenServer owning a named ETS table for concurrent read access.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/cluster/hash_cache_test.exs`:

```elixir
defmodule Uniops.Cluster.HashCacheTest do
  use ExUnit.Case, async: false

  setup do
    # Start a fresh cache for each test
    cache = start_supervised!({Uniops.Cluster.HashCache, name: :test_cache})
    %{cache: cache}
  end

  describe "put/3 and get/2" do
    test "stores and retrieves bytecode by hash", %{cache: cache} do
      data = <<1, 2, 3, 4, 5>>
      hash = Uniops.Cluster.HashCache.put(cache, data)
      assert is_binary(hash)
      assert byte_size(hash) == 64  # SHA256 hex string
      assert {:ok, ^data} = Uniops.Cluster.HashCache.get(cache, hash)
    end

    test "returns :not_found for missing hash", %{cache: cache} do
      assert :not_found = Uniops.Cluster.HashCache.get(cache, "deadbeef")
    end

    test "put with explicit hash", %{cache: cache} do
      data = <<"hello">>
      hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
      assert :ok = Uniops.Cluster.HashCache.put(cache, hash, data)
      assert {:ok, ^data} = Uniops.Cluster.HashCache.get(cache, hash)
    end
  end

  describe "has?/2" do
    test "returns false for missing hash", %{cache: cache} do
      refute Uniops.Cluster.HashCache.has?(cache, "missing")
    end

    test "returns true after put", %{cache: cache} do
      hash = Uniops.Cluster.HashCache.put(cache, <<"data">>)
      assert Uniops.Cluster.HashCache.has?(cache, hash)
    end
  end

  describe "list/1" do
    test "returns empty list initially", %{cache: cache} do
      assert [] = Uniops.Cluster.HashCache.list(cache)
    end

    test "returns all cached hashes", %{cache: cache} do
      h1 = Uniops.Cluster.HashCache.put(cache, <<"a">>)
      h2 = Uniops.Cluster.HashCache.put(cache, <<"b">>)
      hashes = Uniops.Cluster.HashCache.list(cache)
      assert h1 in hashes
      assert h2 in hashes
    end
  end

  describe "hash_of/1" do
    test "computes SHA256 hex" do
      hash = Uniops.Cluster.HashCache.hash_of(<<"hello">>)
      expected = :crypto.hash(:sha256, <<"hello">>) |> Base.encode16(case: :lower)
      assert hash == expected
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/cluster/hash_cache_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Implement HashCache**

Create `lib/uniops/cluster/hash_cache.ex`:

```elixir
defmodule Uniops.Cluster.HashCache do
  @moduledoc """
  ETS-backed cache for Unison bytecode blobs, keyed by SHA256 content hash.
  Provides concurrent read access with sub-microsecond lookups.
  """

  use GenServer

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stores bytecode, computing its SHA256 hash. Returns the hash string.
  """
  def put(server \\ __MODULE__, data) when is_binary(data) do
    hash = hash_of(data)
    put(server, hash, data)
    hash
  end

  @doc """
  Stores bytecode with an explicit hash. Returns :ok.
  """
  def put(server \\ __MODULE__, hash, data) when is_binary(hash) and is_binary(data) do
    GenServer.call(server, {:put, hash, data})
  end

  @doc """
  Retrieves bytecode by hash. Returns `{:ok, data}` or `:not_found`.
  """
  def get(server \\ __MODULE__, hash) when is_binary(hash) do
    # Read directly from ETS for concurrent access (no GenServer call needed)
    table = GenServer.call(server, :table)

    case :ets.lookup(table, hash) do
      [{^hash, data}] -> {:ok, data}
      [] -> :not_found
    end
  end

  @doc """
  Returns true if the hash exists in the cache.
  """
  def has?(server \\ __MODULE__, hash) when is_binary(hash) do
    table = GenServer.call(server, :table)
    :ets.member(table, hash)
  end

  @doc """
  Returns a list of all cached hash strings.
  """
  def list(server \\ __MODULE__) do
    table = GenServer.call(server, :table)
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc """
  Computes the SHA256 hex hash of binary data.
  """
  def hash_of(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(name, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, hash, data}, _from, %{table: table} = state) do
    :ets.insert(table, {hash, data})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:table, _from, %{table: table} = state) do
    {:reply, table, state}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/uniops/cluster/hash_cache_test.exs`
Expected: 7 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add ETS-backed hash cache for Unison bytecode"
jj new
```

---

### Task 2: Sync Server

**Files:**
- Create: `lib/uniops/cluster/sync_server.ex`
- Create: `test/uniops/cluster/sync_server_test.exs`

The SyncServer runs on each node. It does two things:
1. **Serves**: responds to `{:get_hash, hash}` calls from remote nodes with the bytecode
2. **Pulls**: given a list of hashes, checks the local cache and fetches missing ones from peer nodes

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/cluster/sync_server_test.exs`:

```elixir
defmodule Uniops.Cluster.SyncServerTest do
  use ExUnit.Case, async: false

  setup do
    cache = start_supervised!({Uniops.Cluster.HashCache, name: :sync_test_cache})
    sync = start_supervised!({Uniops.Cluster.SyncServer, cache: :sync_test_cache, name: :sync_test_server})
    %{cache: cache, sync: sync}
  end

  describe "fetch_local/2" do
    test "returns bytecode from local cache", %{sync: sync, cache: cache} do
      hash = Uniops.Cluster.HashCache.put(cache, <<"hello">>)
      assert {:ok, <<"hello">>} = Uniops.Cluster.SyncServer.fetch_local(sync, hash)
    end

    test "returns :not_found for missing hash", %{sync: sync} do
      assert :not_found = Uniops.Cluster.SyncServer.fetch_local(sync, "missing")
    end
  end

  describe "resolve/2 (local only, no peers)" do
    test "resolves hashes available locally", %{sync: sync, cache: cache} do
      h1 = Uniops.Cluster.HashCache.put(cache, <<"a">>)
      h2 = Uniops.Cluster.HashCache.put(cache, <<"b">>)

      assert {:ok, resolved} = Uniops.Cluster.SyncServer.resolve(sync, [h1, h2])
      assert Map.keys(resolved) |> Enum.sort() == Enum.sort([h1, h2])
    end

    test "returns error with missing hashes when not available anywhere", %{sync: sync, cache: cache} do
      h1 = Uniops.Cluster.HashCache.put(cache, <<"a">>)

      assert {:error, {:missing, missing}} = Uniops.Cluster.SyncServer.resolve(sync, [h1, "nothere"])
      assert "nothere" in missing
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/cluster/sync_server_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Implement SyncServer**

Create `lib/uniops/cluster/sync_server.ex`:

```elixir
defmodule Uniops.Cluster.SyncServer do
  @moduledoc """
  Syncs bytecode hashes between cluster nodes.

  Each node runs a SyncServer that:
  - Serves hash requests from remote peers (via GenServer.call)
  - Resolves a list of required hashes by checking local cache first,
    then requesting missing hashes from connected peers
  """

  use GenServer

  alias Uniops.Cluster.HashCache

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fetches a hash from the local cache. Used by remote peers.
  """
  def fetch_local(server \\ __MODULE__, hash) do
    GenServer.call(server, {:fetch_local, hash})
  end

  @doc """
  Resolves a list of hashes. Checks local cache first, then asks peers
  for any missing hashes. Returns `{:ok, %{hash => data}}` if all resolved,
  or `{:error, {:missing, [hash]}}` if some couldn't be found anywhere.
  """
  def resolve(server \\ __MODULE__, hashes) when is_list(hashes) do
    GenServer.call(server, {:resolve, hashes}, 30_000)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    cache = Keyword.get(opts, :cache, HashCache)
    {:ok, %{cache: cache}}
  end

  @impl true
  def handle_call({:fetch_local, hash}, _from, %{cache: cache} = state) do
    result = HashCache.get(cache, hash)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:resolve, hashes}, _from, %{cache: cache} = state) do
    {resolved, missing} = check_local(cache, hashes)

    if missing == [] do
      {:reply, {:ok, resolved}, state}
    else
      {from_peers, still_missing} = fetch_from_peers(missing, state)
      resolved = Map.merge(resolved, from_peers)

      # Cache anything we got from peers
      Enum.each(from_peers, fn {hash, data} ->
        HashCache.put(cache, hash, data)
      end)

      if still_missing == [] do
        {:reply, {:ok, resolved}, state}
      else
        {:reply, {:error, {:missing, still_missing}}, state}
      end
    end
  end

  defp check_local(cache, hashes) do
    Enum.reduce(hashes, {%{}, []}, fn hash, {resolved, missing} ->
      case HashCache.get(cache, hash) do
        {:ok, data} -> {Map.put(resolved, hash, data), missing}
        :not_found -> {resolved, [hash | missing]}
      end
    end)
  end

  defp fetch_from_peers(missing, _state) do
    peers = Node.list()

    Enum.reduce(missing, {%{}, []}, fn hash, {found, still_missing} ->
      case ask_peers(peers, hash) do
        {:ok, data} -> {Map.put(found, hash, data), still_missing}
        :not_found -> {found, [hash | still_missing]}
      end
    end)
  end

  defp ask_peers([], _hash), do: :not_found

  defp ask_peers([peer | rest], hash) do
    try do
      case GenServer.call({__MODULE__, peer}, {:fetch_local, hash}, 5_000) do
        {:ok, data} -> {:ok, data}
        :not_found -> ask_peers(rest, hash)
      end
    catch
      :exit, _ -> ask_peers(rest, hash)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/uniops/cluster/sync_server_test.exs`
Expected: 4 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add SyncServer for cross-node hash resolution"
jj new
```

---

### Task 3: Add to Supervision Tree

**Files:**
- Modify: `lib/uniops/application.ex`

- [ ] **Step 1: Update application.ex to start cluster services**

```elixir
defmodule Uniops.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    mnesia_dir = Application.get_env(:uniops, :mnesia_dir)
    if mnesia_dir, do: Uniops.Storage.Schema.init(mnesia_dir)

    children =
      cluster_children() ++ api_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Uniops.Supervisor)
  end

  defp cluster_children do
    [
      Uniops.Cluster.HashCache,
      Uniops.Cluster.SyncServer
    ]
  end

  defp api_children do
    if Application.get_env(:uniops, :start_api, false) do
      port = Application.get_env(:uniops, :api_port, 4040)
      [{Bandit, plug: Uniops.API.Router, port: port}]
    else
      []
    end
  end
end
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `mix test`
Expected: All 49+ tests pass (the HashCache and SyncServer tests use `start_supervised!` with custom names, so they don't conflict with the application-started instances)

- [ ] **Step 3: Commit**

```bash
jj desc -m "Add HashCache and SyncServer to supervision tree"
jj new
```

---

### Task 4: Multi-Node Sync Test

**Files:**
- Create: `test/integration/cluster_sync_test.exs`

This is the key test — two BEAM nodes form a cluster and sync bytecode. Uses OTP's `:peer` module to start an ephemeral peer node.

- [ ] **Step 1: Write the multi-node test**

Create `test/integration/cluster_sync_test.exs`:

```elixir
defmodule Uniops.Integration.ClusterSyncTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  setup_all do
    # Ensure this node is distributed
    case Node.alive?() do
      true ->
        :ok

      false ->
        {:ok, _pid} = :net_kernel.start([:uniops_test, :shortnames])
        :ok
    end

    # Start a peer node with access to our compiled code
    code_paths = :code.get_path() |> Enum.map(&List.to_string/1)
    pa_args = Enum.flat_map(code_paths, fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, _pid, peer_node} =
      :peer.start_link(%{
        name: :uniops_peer1,
        args: List.flatten(pa_args)
      })

    # Start required apps on the peer
    :rpc.call(peer_node, Application, :ensure_all_started, [:crypto])
    :rpc.call(peer_node, Application, :ensure_all_started, [:logger])

    # Start HashCache and SyncServer on the peer
    {:ok, _} = :rpc.call(peer_node, Uniops.Cluster.HashCache, :start_link, [[]])
    {:ok, _} = :rpc.call(peer_node, Uniops.Cluster.SyncServer, :start_link, [[]])

    on_exit(fn ->
      :peer.stop(peer_node)
    end)

    {:ok, peer: peer_node}
  end

  test "hash stored on this node can be fetched by peer via SyncServer", %{peer: peer} do
    # Store bytecode on this (local) node
    data = <<"compiled unison bytecode here">>
    hash = Uniops.Cluster.HashCache.put(data)

    # Verify local node has it
    assert {:ok, ^data} = Uniops.Cluster.HashCache.get(hash)

    # Verify peer does NOT have it yet
    assert :not_found = :rpc.call(peer, Uniops.Cluster.HashCache, :get, [Uniops.Cluster.HashCache, hash])

    # Peer resolves the hash — should pull from us
    assert {:ok, resolved} = :rpc.call(peer, Uniops.Cluster.SyncServer, :resolve, [Uniops.Cluster.SyncServer, [hash]])
    assert resolved[hash] == data

    # Peer should now have it cached locally
    assert {:ok, ^data} = :rpc.call(peer, Uniops.Cluster.HashCache, :get, [Uniops.Cluster.HashCache, hash])
  end

  test "resolve returns missing when hash is not on any node", %{peer: peer} do
    assert {:error, {:missing, ["nonexistent"]}} =
             :rpc.call(peer, Uniops.Cluster.SyncServer, :resolve, [
               Uniops.Cluster.SyncServer,
               ["nonexistent"]
             ])
  end

  test "hash stored on peer can be fetched by this node", %{peer: peer} do
    data = <<"peer bytecode">>

    hash =
      :rpc.call(peer, Uniops.Cluster.HashCache, :put, [Uniops.Cluster.HashCache, data])

    # This node doesn't have it
    assert :not_found = Uniops.Cluster.HashCache.get(hash)

    # Resolve — should pull from peer
    assert {:ok, resolved} = Uniops.Cluster.SyncServer.resolve([hash])
    assert resolved[hash] == data

    # Now cached locally
    assert {:ok, ^data} = Uniops.Cluster.HashCache.get(hash)
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/integration/cluster_sync_test.exs`
Expected: 3 tests, 0 failures

**Debugging notes if tests fail:**
- If `:net_kernel.start` fails, the VM may already be distributed. Check with `Node.alive?()`.
- If `:peer.start_link` fails, ensure OTP 28 is installed (`:peer` was added in OTP 25).
- If `rpc.call` to SyncServer returns `{:badrpc, ...}`, the peer may not have the modules loaded. Check that code paths are correctly forwarded.
- If the sync direction fails (peer can't reach this node), ensure the nodes are connected: `Node.list()` on both should include the other.

- [ ] **Step 3: Commit**

```bash
jj desc -m "Add multi-node cluster sync integration test"
jj new
```

---

### Task 5: Compile-Cache-Sync-Execute End-to-End Test

**Files:**
- Create: `test/integration/cluster_execute_test.exs`

The ultimate proof for Plan 3: compile a Unison program on one node, cache it, sync to a peer, and execute on the peer.

- [ ] **Step 1: Write the end-to-end test**

Create `test/integration/cluster_execute_test.exs`:

```elixir
defmodule Uniops.Integration.ClusterExecuteTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  setup_all do
    # Start distributed node
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:uniops_exec_test, :shortnames])
    end

    # Start peer
    code_paths = :code.get_path() |> Enum.map(&List.to_string/1)
    pa_args = Enum.flat_map(code_paths, fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, _pid, peer_node} =
      :peer.start_link(%{
        name: :uniops_exec_peer,
        args: List.flatten(pa_args)
      })

    :rpc.call(peer_node, Application, :ensure_all_started, [:crypto])
    :rpc.call(peer_node, Application, :ensure_all_started, [:logger])
    {:ok, _} = :rpc.call(peer_node, Uniops.Cluster.HashCache, :start_link, [[]])
    {:ok, _} = :rpc.call(peer_node, Uniops.Cluster.SyncServer, :start_link, [[]])

    on_exit(fn -> :peer.stop(peer_node) end)

    {:ok, peer: peer_node}
  end

  test "compile on local node, sync bytecode to peer, execute on peer", %{peer: peer} do
    # Step 1: Compile a Unison program on this node
    source = """
    main : '{IO, Exception} ()
    main = do printLine "synced-and-executed"
    """

    dir = Path.join(System.tmp_dir!(), "uniops_cluster_exec_#{System.unique_integer([:positive])}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    {:ok, file_path} = Uniops.Workspace.write_source(workspace, "program.u", source)
    {:ok, uc_path} = Uniops.Compiler.compile(workspace, file_path, "main", "program")

    # Step 2: Read the .uc bytecode and cache it locally
    uc_bytes = File.read!(uc_path)
    hash = Uniops.Cluster.HashCache.put(uc_bytes)

    # Step 3: Peer resolves the hash (pulls from us)
    {:ok, _resolved} =
      :rpc.call(peer, Uniops.Cluster.SyncServer, :resolve, [
        Uniops.Cluster.SyncServer,
        [hash]
      ])

    # Step 4: Write the synced bytecode to a temp file on this machine and execute
    # (In a real distributed setup, the peer would write to its own filesystem.
    # Since both nodes share a filesystem in tests, we write to a temp path.)
    {:ok, synced_bytes} =
      :rpc.call(peer, Uniops.Cluster.HashCache, :get, [Uniops.Cluster.HashCache, hash])

    peer_uc_path = Path.join(System.tmp_dir!(), "synced_#{hash}.uc")
    File.write!(peer_uc_path, synced_bytes)

    # Execute the synced bytecode
    {:ok, result} = Uniops.Runner.run_compiled(peer_uc_path)
    assert result.stdout =~ "synced-and-executed"

    # Cleanup
    File.rm(peer_uc_path)
    Uniops.Workspace.destroy(workspace)
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/integration/cluster_execute_test.exs`
Expected: 1 test, 0 failures

This proves the full pipeline: Unison source → compile → cache bytecode → sync to peer node → execute.

- [ ] **Step 3: Commit**

```bash
jj desc -m "Add end-to-end compile-cache-sync-execute cluster test"
jj new
```

---

### Task 6: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `mix test --trace`
Expected: All tests pass (49 existing + ~14 new cluster tests)

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation

- [ ] **Step 3: Verify cluster tests specifically**

Run: `mix test test/uniops/cluster/ test/integration/cluster_sync_test.exs test/integration/cluster_execute_test.exs --trace`
Expected: All cluster tests pass

- [ ] **Step 4: Commit final state**

```bash
jj desc -m "Complete Plan 3: BEAM clustering with hash cache and sync"
```

---

## What This Plan Produces

1. **HashCache** — ETS-backed GenServer storing bytecode by SHA256, with concurrent reads
2. **SyncServer** — cross-node hash resolution: checks local cache, asks peers for missing hashes, caches results
3. **Multi-node tests** — proven bytecode sync between two BEAM nodes using `:peer`
4. **Full pipeline test** — compile Unison → cache → sync to peer → execute

This is the distribution infrastructure. Plan 4 (Remote handler) will use `SyncServer.resolve/2` to ensure a peer has all required bytecode before asking it to execute a computation.
