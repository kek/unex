# Dispatcher Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `Unex.Dispatcher` GenServer with a NimblePool-backed pool of N persistent UCM subprocesses, eliminating head-of-line blocking on concurrent service calls.

**Architecture:** A new `Unex.Dispatcher.Pool` module implements `NimblePool.Worker`, managing N independent `Dispatcher` GenServers (each with its own UCM subprocess and TCP socket). `Services.eval_local` calls `Pool.eval/2` instead of `Dispatcher.eval/3`; `Application` supervises `Pool` instead of `Dispatcher`. The existing `Dispatcher` module is unchanged.

**Tech Stack:** Elixir, NimblePool (`~> 1.1`), existing `Unex.Dispatcher` GenServer.

---

## File Map

| Action | File | What changes |
|---|---|---|
| Modify | `mix.exs` | Add `nimble_pool` dep |
| Modify | `config/config.exs` | Add `dispatcher_pool_size: 4` |
| Modify | `config/test.exs` | Add `dispatcher_pool_size: 1` |
| Modify | `config/runtime.exs` | Add `UNEX_DISPATCHER_POOL_SIZE` env var resolution |
| Create | `lib/unex/dispatcher/pool.ex` | New NimblePool worker + public API |
| Modify | `lib/unex/application.ex` | Supervise Pool instead of Dispatcher |
| Modify | `lib/unex/services.ex` | Use Pool.eval/Pool.available? |
| Modify | `test/integration/service_lifecycle_test.exs` | Start Pool, adjust assertions |
| Modify | `docs/architecture.md` | Update single-inflight description |

---

### Task 1: Add nimble_pool dependency and config

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Add nimble_pool to mix.exs**

In `mix.exs`, add `{:nimble_pool, "~> 1.1"}` to the `deps/0` list:

```elixir
defp deps do
  [
    {:plug, "~> 1.16"},
    {:bandit, "~> 1.6"},
    {:jason, "~> 1.4"},
    {:nimble_pool, "~> 1.1"},
    {:phoenix, "~> 1.7.14"},
    # ... rest unchanged
  ]
end
```

- [ ] **Step 2: Add pool size default to config/config.exs**

In `config/config.exs`, add `dispatcher_pool_size: 4` to the existing `:unex` config block:

```elixir
config :unex,
  ucm_path: "ucm",
  ucm_timeout: 30_000,
  workspace_base: Path.join(System.tmp_dir!(), "unex"),
  api_port: 4040,
  start_api: false,
  start_dashboard: false,
  dispatcher_pool_size: 4,
  # ... rest unchanged
```

- [ ] **Step 3: Add pool size to test config**

In `config/test.exs`, add `dispatcher_pool_size: 1` so integration tests start exactly one UCM subprocess:

```elixir
config :unex,
  start_api: false,
  start_dispatcher: false,
  dispatcher_pool_size: 1,
  mnesia_dir: nil,
  blobs_dir: nil,
  hash_cache_dir: nil,
  config_encryption_key: "test-key-not-for-production",
  api_secret: "test-secret"
```

- [ ] **Step 4: Add UNEX_DISPATCHER_POOL_SIZE to runtime.exs**

In `config/runtime.exs`, after the `dispatcher_path` line (around line 80), add pool size resolution using the existing `get_int` helper. Then add `dispatcher_pool_size` to the `config :unex` block:

```elixir
dispatcher_path = System.get_env("UNEX_DISPATCHER") || Map.get(file_config, :dispatcher_path)
pool_size = get_int.("UNEX_DISPATCHER_POOL_SIZE", :dispatcher_pool_size, 4)

# --- Apply config ---
config :unex,
  api_port: get_int.("UNEX_PORT", :api_port, 4040),
  api_url: get.("UNEX_API_URL", :api_url, nil),
  mnesia_dir: Path.join(data_dir, "mnesia"),
  blobs_dir: Path.join(data_dir, "blobs"),
  hash_cache_dir: Path.join(data_dir, "hashcache"),
  config_encryption_key: encryption_key,
  api_secret: api_secret,
  ucm_path: get.("UCM_PATH", :ucm_path, "ucm"),
  dispatcher_path: dispatcher_path,
  dispatcher_pool_size: pool_size,
  peers: peers,
  node_name: node_name,
  cookie: cookie,
  start_api: true
```

- [ ] **Step 5: Fetch deps**

```bash
cd /Users/ke/src/unex && mix deps.get
```

Expected: nimble_pool appears in the resolved dependency list.

---

### Task 2: Create Unex.Dispatcher.Pool

**Files:**
- Create: `lib/unex/dispatcher/pool.ex`

- [ ] **Step 1: Create the pool module**

Create `lib/unex/dispatcher/pool.ex` with the full content:

```elixir
defmodule Unex.Dispatcher.Pool do
  @moduledoc """
  NimblePool-backed pool of `Unex.Dispatcher` workers.

  Each pool slot holds one persistent UCM subprocess and its TCP protocol
  socket. Concurrent service calls are distributed across workers; when all
  workers are busy, callers queue inside NimblePool until a worker is free or
  the timeout elapses.

  Pool size is controlled by the `:dispatcher_pool_size` application config key
  (env: `UNEX_DISPATCHER_POOL_SIZE`). Default: 4.
  """

  @behaviour NimblePool

  require Logger

  @default_timeout 60_000

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  def start_link(opts \\ []) do
    pool_size =
      Keyword.get(opts, :pool_size, Application.get_env(:unex, :dispatcher_pool_size, 4))

    NimblePool.start_link(
      worker: {__MODULE__, []},
      pool_size: pool_size,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Evaluate a serialized `Value` thunk using a free pool worker.

  Blocks until a worker is available or `timeout` ms elapse.
  Returns `{:ok, result_text}` or `{:error, reason}`.
  """
  def eval(bytes, timeout \\ @default_timeout) do
    try do
      NimblePool.checkout!(__MODULE__, :checkout, fn _from, pid ->
        result = Unex.Dispatcher.eval(pid, bytes, timeout)
        {result, :ok}
      end, timeout)
    rescue
      NimblePool.Timeout -> {:error, :pool_timeout}
    catch
      :exit, reason -> {:error, {:worker_exit, reason}}
    end
  end

  @doc "Returns `true` if the pool process is registered and alive."
  def available? do
    Process.whereis(__MODULE__) != nil
  end

  # --------------------------------------------------------------------------
  # NimblePool.Worker callbacks
  # --------------------------------------------------------------------------

  @impl NimblePool
  def init_worker(pool_state) do
    {:ok, pid} = Unex.Dispatcher.start_link(name: nil)
    {:ok, pid, pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, pid, pool_state) do
    if Unex.Dispatcher.running?(pid) do
      {:ok, pid, pid, pool_state}
    else
      {:remove, :not_running, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin(:ok, _from, pid, pool_state) do
    {:ok, pid, pool_state}
  end

  @impl NimblePool
  def terminate_worker(_reason, pid, pool_state) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    {:ok, pool_state}
  end
end
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/ke/src/unex && mix compile 2>&1 | grep -E "(error|warning|pool)"
```

Expected: no errors. May see warnings about unused variables if the supervisor tree references old Dispatcher — those get fixed in the next tasks.

---

### Task 3: Update Application supervisor

**Files:**
- Modify: `lib/unex/application.ex`

- [ ] **Step 1: Replace Dispatcher with Dispatcher.Pool**

In `lib/unex/application.ex`, the `cluster_children/0` function currently ends with:

```elixir
if Application.get_env(:unex, :start_dispatcher, true) do
  base ++ [Unex.Dispatcher]
else
  base
end
```

Replace with:

```elixir
if Application.get_env(:unex, :start_dispatcher, true) do
  pool_size = Application.get_env(:unex, :dispatcher_pool_size, 4)
  base ++ [{Unex.Dispatcher.Pool, pool_size: pool_size}]
else
  base
end
```

- [ ] **Step 2: Verify compilation**

```bash
cd /Users/ke/src/unex && mix compile 2>&1 | grep -i error
```

Expected: no errors.

---

### Task 4: Update Services.eval_local

**Files:**
- Modify: `lib/unex/services.ex`

- [ ] **Step 1: Update the docstring**

In `lib/unex/services.ex`, update the `@moduledoc` to reference Pool:

Change the phrase `a long-lived \`Unex.Dispatcher\` process` to `a pool of long-lived \`Unex.Dispatcher\` processes via \`Unex.Dispatcher.Pool\``.

- [ ] **Step 2: Update eval_local/2**

The current `eval_local/2` function (lines 55–72) references `Unex.Dispatcher.running?()` and `Unex.Dispatcher.eval(Unex.Dispatcher, data, timeout)`. Replace the entire function:

```elixir
@doc """
Resolves the root `Value` bytes for a service hash and hands them to the
local `Unex.Dispatcher.Pool` for evaluation. Public because it is called via
RPC from remote nodes.
"""
def eval_local(hash, timeout) do
  cond do
    not Unex.Dispatcher.Pool.available?() ->
      {:error, :dispatcher_not_started}

    true ->
      with {:ok, resolved} <- SyncServer.resolve([hash]),
           data when is_binary(data) <- Map.get(resolved, hash) do
        case Unex.Dispatcher.Pool.eval(data, timeout) do
          {:ok, text} -> {:ok, %Result{stdout: text, stderr: "", exit_code: 0}}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, _} = err -> err
        nil -> {:error, {:missing, hash}}
      end
  end
end
```

- [ ] **Step 3: Verify compilation**

```bash
cd /Users/ke/src/unex && mix compile 2>&1 | grep -i error
```

Expected: no errors.

---

### Task 5: Update integration test

**Files:**
- Modify: `test/integration/service_lifecycle_test.exs`

The test currently starts a single `Dispatcher` and asserts exactly one UCM subprocess runs. With a pool of size 1 (set in `config/test.exs`), the count stays at 1 — we just swap the started process.

- [ ] **Step 1: Update setup_all to start Pool**

In `test/integration/service_lifecycle_test.exs`, the `setup_all` block (around line 27) currently has:

```elixir
{:ok, dispatcher_pid} = Unex.Dispatcher.start_link()
```

Replace those two lines (start + on_exit for dispatcher) with Pool equivalents. Find and replace the setup block section from `{:ok, dispatcher_pid}` through the closing of `on_exit`:

Current (lines 53–66):
```elixir
{:ok, dispatcher_pid} = Unex.Dispatcher.start_link()

on_exit(fn ->
  if Process.alive?(dispatcher_pid), do: GenServer.stop(dispatcher_pid, :normal, 5_000)
  Process.exit(bandit_pid, :normal)
  :mnesia.stop()
  File.rm_rf!(mnesia_dir)

  if old_api_port do
    Application.put_env(:unex, :api_port, old_api_port)
  else
    Application.delete_env(:unex, :api_port)
  end
end)
```

Replace with:
```elixir
{:ok, pool_pid} = Unex.Dispatcher.Pool.start_link()

on_exit(fn ->
  if Process.alive?(pool_pid), do: GenServer.stop(pool_pid, :normal, 10_000)
  Process.exit(bandit_pid, :normal)
  :mnesia.stop()
  File.rm_rf!(mnesia_dir)

  if old_api_port do
    Application.put_env(:unex, :api_port, old_api_port)
  else
    Application.delete_env(:unex, :api_port)
  end
end)
```

- [ ] **Step 2: Update the UCM subprocess count assertion**

The test currently asserts (around line 144–146):

```elixir
assert ucm_count == 1,
       "expected exactly one UCM subprocess for the whole session, found #{ucm_count}"
```

The pool size is 1 in test config, so this assertion stays valid. But update the message to reflect the pool:

```elixir
pool_size = Application.get_env(:unex, :dispatcher_pool_size, 1)

assert ucm_count == pool_size,
       "expected #{pool_size} UCM subprocess(es) (pool_size=#{pool_size}), found #{ucm_count}"
```

Note: add `pool_size = Application.get_env(:unex, :dispatcher_pool_size, 1)` just before the assertion.

- [ ] **Step 3: Verify the test file compiles**

```bash
cd /Users/ke/src/unex && mix compile --no-deps-check 2>&1 | grep -i error
```

Expected: no errors.

---

### Task 6: Update architecture docs

**Files:**
- Modify: `docs/architecture.md`

- [ ] **Step 1: Update the Execution section**

In `docs/architecture.md`, around line 88, the section begins:

> A single long-lived dispatcher process evaluates every service call. There is no per-call UCM subprocess.

Replace lines 88–103 (the Execution section through the Concurrency paragraph) with:

```markdown
A pool of long-lived dispatcher processes evaluates service calls. There is no per-call UCM subprocess.

**Boot:** On app start, `Unex.Dispatcher.Pool` starts N `Unex.Dispatcher` workers (N = `:dispatcher_pool_size`, default 4, env: `UNEX_DISPATCHER_POOL_SIZE`). Each worker listens on `127.0.0.1:0` and spawns `ucm run.compiled $UNEX_DISPATCHER`. The Unison program reads `UNEX_DISPATCHER_PORT` from its environment, connects back via `Socket.client`, and enters a request loop. Elixir accepts the one incoming connection per worker.

**Per request (`POST /services/:name/call` or `GET /<name>`):**

1. `Services.Registry.resolve(name)` returns the current root-value hash. On a node that doesn't own the entry, the registry GenServer falls back to `ask_peers(Node.list(), name)` and `GenServer.call({Registry, peer}, {:lookup, name})` on each connected peer until one answers.
2. `SyncServer.resolve([hash])` returns the serialized `Value` bytes. Local `HashCache` first; on miss, `ask_peers` does `GenServer.call({SyncServer, peer}, {:fetch_local, hash})` on each connected peer. Anything fetched is immediately `HashCache.put`'d so the next call is local.
3. `Unex.Dispatcher.Pool.eval` checks out a free worker from the pool. If all workers are busy the caller blocks until one is free or the timeout elapses (`{:error, :pool_timeout}`).
4. The checked-out `Unex.Dispatcher` sends `<<len::8, value_bytes>>` over its protocol socket to its UCM subprocess.
5. The Unison dispatcher `Value.deserialize`s, `Value.load`s as a `'{IO, Exception} ()` thunk, and **iteratively satisfies missing `Code` deps** by issuing `GET /code/:termhash` back to its own node's API. Fetched codes are `Code.cache_`'d; `Value.load` is retried until all deps resolve.
6. The thunk runs for its side effects. Anything the user program writes to `stdout` is captured by Elixir from the subprocess's pipe (the protocol is on a separate socket, so `printLine` is free to use stdout).
7. On completion, the dispatcher sends an OK response frame. Elixir wraps the accumulated stdout in `%Runner.Result{stdout: ..., stderr: "", exit_code: 0}`, checks the worker back into the pool, and returns to the caller.

Because dispatchers are persistent, typical service calls complete in single-digit milliseconds instead of the several seconds a cold `ucm run.compiled` takes.

**Concurrency.** N concurrent calls can execute simultaneously without head-of-line blocking. Additional callers queue inside NimblePool until a worker is free.
```

---

### Task 7: Final compilation and test smoke-check

**Files:** none (verification only)

- [ ] **Step 1: Full compile**

```bash
cd /Users/ke/src/unex && mix compile 2>&1
```

Expected: `Compiled lib/unex/dispatcher/pool.ex` in the output, no errors.

- [ ] **Step 2: Run non-integration tests**

```bash
cd /Users/ke/src/unex && mix test --exclude integration 2>&1 | tail -20
```

Expected: all tests pass. (Integration tests require `ucm` on PATH and `dispatcher.uc` — skip them in CI unless those conditions hold.)

---

### Task 8: Commit

- [ ] **Step 1: Describe the jj commit and commit all changes**

```bash
cd /Users/ke/src/unex
jj desc -m "Add dispatcher pool (NimblePool-backed concurrency)

Replace single Unex.Dispatcher with Unex.Dispatcher.Pool backed by
NimblePool. N persistent UCM subprocesses handle concurrent service calls
without head-of-line blocking. Pool size configured via
UNEX_DISPATCHER_POOL_SIZE (default 4)."
jj st
```

Expected: all modified/added files shown in the diff.
