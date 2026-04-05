# Remote Handler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable executing compiled Unison bytecode on any node in the cluster — the `Remote.fork` equivalent that ships a computation to a peer, syncs its dependencies, runs it, and returns the result.

**Architecture:** A single `Uniops.Remote` module (no GenServer needed) coordinates the existing building blocks: `SyncServer.resolve/1` ensures bytecode is available on the target node, `Runner.run_compiled/2` executes it, and `:rpc.call/5` bridges across nodes. `execute/2` runs a hash on a specific node, `submit/2` picks a peer automatically. All synchronous — the caller blocks until the result arrives.

**Tech Stack:** Elixir 1.19 / OTP 28, existing Uniops modules (HashCache, SyncServer, Runner), `:rpc` for cross-node calls, `:peer` for testing

---

## Scope Note

This is Plan 4 of 6. It delivers the core computation-shipping capability. What it covers:
- Execute bytecode (by hash) on a local or remote node
- Auto-sync dependencies to target via SyncServer
- Submit work to any available peer

What it does **not** cover:
- Async execution / futures (caller blocks for now)
- Worker pools / load balancing (uses `Enum.random` for peer selection)
- Persistent daemons (long-running restarting processes)
- The actual Unison `Remote` ability handler (that requires writing Unison code)

## Prerequisites

- Plans 1-3 completed (UCM integration, storage, clustering)

## File Structure

```
lib/
  uniops/
    remote.ex                       # Public API: execute, submit, do_execute (called via RPC)
test/
  uniops/
    remote_test.exs                 # Local execution tests
  integration/
    remote_execute_test.exs         # Multi-node: compile on A, execute on B via Remote
```

---

### Task 1: Remote Module — Local Execution

**Files:**
- Create: `lib/uniops/remote.ex`
- Create: `test/uniops/remote_test.exs`

Start with local execution — `execute/2` with no `:node` option runs locally.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/remote_test.exs`:

```elixir
defmodule Uniops.RemoteTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  setup do
    # Compile a simple Unison program and cache its bytecode
    source = """
    main : '{IO, Exception} ()
    main = do printLine "remote-ok"
    """

    dir = Path.join(System.tmp_dir!(), "uniops_remote_test_#{System.unique_integer([:positive])}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    {:ok, file_path} = Uniops.Workspace.write_source(workspace, "program.u", source)
    {:ok, uc_path} = Uniops.Compiler.compile(workspace, file_path, "main", "program")

    uc_bytes = File.read!(uc_path)
    hash = Uniops.Cluster.HashCache.put(uc_bytes)

    on_exit(fn -> Uniops.Workspace.destroy(workspace) end)

    %{hash: hash}
  end

  describe "execute/2 (local)" do
    test "executes bytecode by hash on the local node", %{hash: hash} do
      assert {:ok, result} = Uniops.Remote.execute(hash)
      assert result.stdout =~ "remote-ok"
    end

    test "returns error for unknown hash" do
      assert {:error, _} = Uniops.Remote.execute("0000000000000000000000000000000000000000000000000000000000000000")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/remote_test.exs`
Expected: FAIL — `Uniops.Remote` not found

- [ ] **Step 3: Implement the Remote module**

Create `lib/uniops/remote.ex`:

```elixir
defmodule Uniops.Remote do
  @moduledoc """
  Executes compiled Unison bytecode on local or remote cluster nodes.

  Coordinates HashCache (bytecode storage), SyncServer (cross-node sync),
  and Runner (UCM execution) to ship and run computations anywhere in the cluster.
  """

  @doc """
  Executes bytecode identified by `hash` on a target node.

  Options:
    - `:node` - target node (default: current node)
    - `:timeout` - execution timeout in ms (default: 60_000)
    - `:args` - arguments to pass to the Unison program

  Returns `{:ok, %Runner.Result{}}` or `{:error, reason}`.
  """
  def execute(hash, opts \\ []) do
    target = Keyword.get(opts, :node, node())
    timeout = Keyword.get(opts, :timeout, 60_000)

    if target == node() do
      do_execute(hash, opts)
    else
      case :rpc.call(target, __MODULE__, :do_execute, [hash, opts], timeout) do
        {:badrpc, reason} -> {:error, {:rpc_failed, target, reason}}
        result -> result
      end
    end
  end

  @doc """
  Submits bytecode for execution on any available peer node.
  Falls back to local execution if no peers are connected.

  Same options as `execute/2`.
  """
  def submit(hash, opts \\ []) do
    target =
      case Node.list() do
        [] -> node()
        peers -> Enum.random(peers)
      end

    execute(hash, Keyword.put(opts, :node, target))
  end

  @doc """
  Executes bytecode locally. Called directly or via RPC from a remote node.

  1. Resolves the hash via SyncServer (pulls from peers if needed)
  2. Writes bytecode to a temp .uc file
  3. Runs via Runner.run_compiled
  4. Cleans up the temp file
  """
  def do_execute(hash, opts \\ []) do
    case Uniops.Cluster.SyncServer.resolve([hash]) do
      {:ok, resolved} ->
        bytecode = Map.fetch!(resolved, hash)
        run_bytecode(hash, bytecode, opts)

      {:error, {:missing, _}} = err ->
        err
    end
  end

  defp run_bytecode(hash, bytecode, opts) do
    path = Path.join(System.tmp_dir!(), "uniops_exec_#{hash}.uc")
    File.write!(path, bytecode)

    try do
      Uniops.Runner.run_compiled(path, Keyword.take(opts, [:timeout, :args]))
    after
      File.rm(path)
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/remote_test.exs`
Expected: 2 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add Remote module for executing bytecode on local or remote nodes"
jj new
```

---

### Task 2: Multi-Node Remote Execution Test

**Files:**
- Create: `test/integration/remote_execute_test.exs`

Proves the full pipeline across nodes: compile on node A, execute on node B via `Remote.execute/2`, get the result back.

- [ ] **Step 1: Write the multi-node test**

Create `test/integration/remote_execute_test.exs`:

```elixir
defmodule Uniops.Integration.RemoteExecuteTest do
  use ExUnit.Case, async: false

  alias Uniops.Cluster.{HashCache, SyncServer}

  @moduletag timeout: 300_000

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:uniops_remote_test, :shortnames])
    end

    :ok
  end

  setup do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    {:ok, pid, peer} = :peer.start_link(%{name: :remote_peer, args: pa_args})

    {:ok, _} = :rpc.call(peer, Application, :ensure_all_started, [:crypto])
    {:ok, _} = :rpc.call(peer, GenServer, :start, [HashCache, HashCache, [name: HashCache]])
    {:ok, _} = :rpc.call(peer, GenServer, :start, [SyncServer, %{cache: HashCache}, [name: SyncServer]])

    on_exit(fn ->
      try do
        :peer.stop(pid)
      catch
        _, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  test "execute bytecode on a remote peer node", %{peer: peer} do
    # Compile locally
    source = """
    main : '{IO, Exception} ()
    main = do printLine "executed-on-peer"
    """

    dir = Path.join(System.tmp_dir!(), "uniops_remote_exec_#{System.unique_integer([:positive])}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    {:ok, file_path} = Uniops.Workspace.write_source(workspace, "program.u", source)
    {:ok, uc_path} = Uniops.Compiler.compile(workspace, file_path, "main", "program")

    # Cache bytecode locally
    uc_bytes = File.read!(uc_path)
    hash = HashCache.put(uc_bytes)

    # Execute on peer — peer will pull bytecode from us via SyncServer
    assert {:ok, result} = Uniops.Remote.execute(hash, node: peer, timeout: 120_000)
    assert result.stdout =~ "executed-on-peer"

    Uniops.Workspace.destroy(workspace)
  end

  test "submit picks a peer and executes", %{peer: peer} do
    # Compile and cache
    source = """
    main : '{IO, Exception} ()
    main = do printLine "submitted-ok"
    """

    dir = Path.join(System.tmp_dir!(), "uniops_submit_#{System.unique_integer([:positive])}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    {:ok, file_path} = Uniops.Workspace.write_source(workspace, "program.u", source)
    {:ok, uc_path} = Uniops.Compiler.compile(workspace, file_path, "main", "program")

    hash = HashCache.put(File.read!(uc_path))

    # Submit — should pick the peer (only connected node)
    assert {:ok, result} = Uniops.Remote.submit(hash, timeout: 120_000)
    assert result.stdout =~ "submitted-ok"

    Uniops.Workspace.destroy(workspace)
  end

  test "execute returns error for unreachable node" do
    hash = HashCache.put(<<"fake bytecode">>)

    assert {:error, {:rpc_failed, :nonexistent@nohost, _}} =
             Uniops.Remote.execute(hash, node: :nonexistent@nohost, timeout: 5_000)
  end
end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/integration/remote_execute_test.exs`
Expected: 3 tests, 0 failures

**Debugging notes:**
- If the peer can't execute (`:badrpc`), ensure UCM is on PATH — the peer inherits the same PATH since it's on the same machine.
- If `do_execute` fails on the peer with `{:error, {:missing, [hash]}}`, the peer's SyncServer isn't connecting to us. Check `Node.list()` on the peer via `:rpc.call(peer, Node, :list, [])`.
- If `Runner.run_compiled` fails on the peer, it might be because the Runner process tries to find UCM. Verify with `:rpc.call(peer, Uniops.UCM, :find, [])`.

- [ ] **Step 3: Commit**

```bash
jj desc -m "Add multi-node remote execution integration tests"
jj new
```

---

### Task 3: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: All tests pass (65 existing + ~5 new remote tests)

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation

- [ ] **Step 3: Run just the remote tests with trace**

Run: `mix test test/uniops/remote_test.exs test/integration/remote_execute_test.exs --trace`
Expected: 5 tests, 0 failures

- [ ] **Step 4: Commit final state**

```bash
jj desc -m "Complete Plan 4: Remote handler for cross-node computation"
```

---

## What This Plan Produces

1. **`Uniops.Remote.execute/2`** — execute bytecode (by hash) on any node in the cluster
2. **`Uniops.Remote.submit/2`** — execute on any available peer (random selection)
3. **`Uniops.Remote.do_execute/2`** — the local execution path (also callable via RPC)
4. **Proven multi-node execution** — compile on A, execute on B, result returned to A

This completes the core computation-shipping capability. Combined with Plans 1-3:
- Plan 1: UCM management (compile, run)
- Plan 2: Storage (Mnesia + HTTP API)
- Plan 3: Clustering (hash cache + sync)
- Plan 4: Remote execution (this plan)

Plan 5 (Services) will add a typed RPC registry on top of this — `deploy` registers a function, `Services.call` routes to the right node. Plan 6 adds Config, Blobs, Scratch, and Log.
