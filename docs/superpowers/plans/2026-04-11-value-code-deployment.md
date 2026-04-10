# Value + Code Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken `Code.serialize_v3` + `ucm run.compiled` deployment with Unison Cloud-style Value + Code serialization, using an executor program to load bundles on the server.

**Architecture:** The client serializes the function closure via `Value.value` + `Value.serialize` and gathers all code dependencies via `Value.dependencies` + `Code.lookup` + `Code.serialize`. These are packed into a binary bundle and pushed to the server. The server stores the bundle in HashCache by SHA256 hash. When a service is called, the server writes the bundle to a temp file and runs a pre-compiled executor program (`executor.uc`) that reads the bundle, caches the code dependencies via `Code.cache_`, loads the function via `Value.load`, and executes it.

**Tech Stack:** Elixir/BEAM, Unison (Value, Code, Link.Term builtins), UCM subprocess.

---

## File Map

**Create:**
- `unison/executor.u` — Executor source: reads bundle, caches code, loads + runs value
- `lib/unex/executor.ex` — GenServer: manages executor.uc path, compiles on startup

**Modify:**
- `unison/Unex/Services.u` — `deploy : Text -> '{IO, Exception} () -> Text`, Value+Code handler
- `lib/unex/api/bytecode_controller.ex` — Add `push/1` (hashless POST), remove `put/2`
- `lib/unex/api/router.ex` — Replace `POST /bytecode/:hash` with `POST /bytecode`
- `lib/unex/remote.ex` — `do_execute/2` uses executor + bundle file
- `lib/unex/application.ex` — Add `Unex.Executor` to supervision tree
- `test/example/service.u` — Merged single-file deploy example
- `test/example/call.u` — Updated
- `test/unex/remote_test.exs` — Updated for executor-based execution
- `test/unex/api/bytecode_api_test.exs` — Updated for new endpoint
- `docs/guide.md` — Part 9 rewritten, Part 11 added (@kek/unex release)
- `docs/api.md` — Bytecode section updated
- `CLAUDE.md` — Architecture updated

**Remove:**
- `test/example/deploy.u` — Merged into service.u

---

## Task 1: Write executor source

**Files:**
- Create: `unison/executor.u`

The executor reads a bundle file, caches code dependencies, loads the function value, and executes it. It needs to work in a Unison codebase with `@unison/base` installed.

- [ ] **Step 1: Create executor.u**

```unison
-- Unex Executor
-- Reads a deployment bundle from a file, caches code dependencies,
-- loads the function value, and executes it.
--
-- Bundle format:
--   [4 bytes: deps section length, big-endian u32]
--   [deps section: Value.serialize'd [(Link.Term, Bytes)]]
--   [remaining: Value.serialize'd function closure]
--
-- Environment:
--   UNEX_BUNDLE — path to the bundle file (required)
--   UNEX_URL    — server URL (passed through to the executed function)
--   UNEX_SECRET — auth token (passed through to the executed function)

executor.readU32 : Bytes -> Nat
executor.readU32 bytes =
  use Nat + *
  b0 = match Bytes.at 0 bytes with
    Some n -> n
    None -> bug "executor: bundle too short for length header"
  b1 = match Bytes.at 1 bytes with
    Some n -> n
    None -> bug "executor: bundle too short for length header"
  b2 = match Bytes.at 2 bytes with
    Some n -> n
    None -> bug "executor: bundle too short for length header"
  b3 = match Bytes.at 3 bytes with
    Some n -> n
    None -> bug "executor: bundle too short for length header"
  b0 * 16777216 + b1 * 65536 + b2 * 256 + b3

executor.deserializeCodes : [(Link.Term, Bytes)] -> [(Link.Term, Code)]
executor.deserializeCodes pairs =
  match pairs with
    [] -> []
    (link, bytes) +: rest ->
      match Code.deserialize bytes with
        Left err -> bug ("executor: Code.deserialize failed: " ++ err)
        Right code -> (link, code) +: executor.deserializeCodes rest

executor : '{IO, Exception} ()
executor = do
  bundlePath = match catch do IO.getEnv "UNEX_BUNDLE" with
    Left _ -> bug "executor: UNEX_BUNDLE env var not set"
    Right p -> p

  bundle = readFileBytes bundlePath

  -- Parse bundle header
  depsLen = executor.readU32 bundle
  depsBytes = Bytes.drop 4 bundle |> Bytes.take depsLen
  fnBytes = Bytes.drop (4 + depsLen) bundle

  -- Load code dependencies (only references builtin types, always loadable)
  depsVal = match Value.deserialize depsBytes with
    Left err -> bug ("executor: deps deserialize failed: " ++ err)
    Right v -> v
  codePairs : [(Link.Term, Bytes)]
  codePairs = match Value.load depsVal with
    Left _missing -> bug "executor: deps Value.load failed"
    Right pairs -> pairs

  -- Cache all code into the runtime
  codeEntries = executor.deserializeCodes codePairs
  _ = Code.cache_ codeEntries

  -- Load and execute the function
  fnVal = match Value.deserialize fnBytes with
    Left err -> bug ("executor: function deserialize failed: " ++ err)
    Right v -> v
  fn : '{IO, Exception} ()
  fn = match Value.load fnVal with
    Left _missing -> bug "executor: function Value.load failed (missing deps after cache)"
    Right f -> f
  !fn
```

Note: `readFileBytes` is from the Unison base library. The exact API name may need adjustment when loading in UCM — check with `find readFileBytes` in UCM. If unavailable, use `IO.openFile` + `Handle.getBytes` + `Handle.closeFile`.

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add executor.u: bundle loader for Value+Code deployment"
jj new
```

---

## Task 2: Add Executor GenServer

**Files:**
- Create: `lib/unex/executor.ex`
- Modify: `lib/unex/application.ex`

The GenServer manages the path to executor.uc. On startup, it checks if executor.uc exists at `{data_dir}/executor.uc`. If not, it attempts to compile from `unison/executor.u` using the Compiler module. For POC, if auto-compilation fails, it logs an error with manual compilation instructions.

- [ ] **Step 1: Create lib/unex/executor.ex**

```elixir
defmodule Unex.Executor do
  @moduledoc """
  Manages the executor.uc compiled program used to run deployed service bundles.

  On startup, checks for executor.uc at the configured data directory.
  If missing, attempts auto-compilation from unison/executor.u source.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the path to executor.uc, or {:error, reason} if not available."
  def executor_path(server \\ __MODULE__) do
    GenServer.call(server, :executor_path)
  end

  @impl true
  def init(_opts) do
    uc_path = Path.join(data_dir(), "executor.uc")

    state =
      if File.exists?(uc_path) do
        Logger.info("Executor ready: #{uc_path}")
        %{path: uc_path}
      else
        case try_compile(uc_path) do
          {:ok, path} ->
            Logger.info("Executor compiled: #{path}")
            %{path: path}

          {:error, reason} ->
            Logger.warning("""
            Executor not available: #{reason}

            To compile manually, run in a Unison project with @unison/base installed:
              load unison/executor.u
              add
              compile executor #{uc_path}
            """)

            %{path: nil}
        end
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:executor_path, _from, %{path: nil} = state) do
    {:reply, {:error, :not_compiled}, state}
  end

  def handle_call(:executor_path, _from, %{path: path} = state) do
    {:reply, {:ok, path}, state}
  end

  defp try_compile(uc_path) do
    source = Path.join(source_dir(), "executor.u")

    unless File.exists?(source) do
      {:error, "executor.u source not found at #{source}"}
    else
      File.mkdir_p!(Path.dirname(uc_path))

      dir = Path.join(System.tmp_dir!(), "unex_executor_ws_#{System.unique_integer([:positive])}")

      case Unex.Workspace.create(dir) do
        {:ok, workspace} ->
          try do
            case Unex.Compiler.compile(workspace, source, "executor", Path.rootname(uc_path)) do
              {:ok, compiled_path} ->
                if compiled_path != uc_path do
                  File.cp!(compiled_path, uc_path)
                end

                {:ok, uc_path}

              {:error, reason} ->
                {:error, "compilation failed: #{inspect(reason)}"}
            end
          after
            Unex.Workspace.destroy(workspace)
          end

        {:error, reason} ->
          {:error, "workspace creation failed: #{inspect(reason)}"}
      end
    end
  end

  defp data_dir do
    Application.get_env(:unex, :data_dir, "data")
  end

  defp source_dir do
    Application.get_env(:unex, :source_dir, "unison")
  end
end
```

- [ ] **Step 2: Add to supervision tree**

In `lib/unex/application.ex`, add `Unex.Executor` to the `cluster_children/0` list:

```elixir
defp cluster_children do
  [
    Unex.Cluster.HashCache,
    Unex.Cluster.SyncServer,
    Unex.Services.Registry,
    Unex.Abilities.Scratch,
    Unex.Abilities.Log,
    Unex.Executor
  ]
end
```

- [ ] **Step 3: Verify it compiles**

```bash
mix compile
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
jj desc -m "Add Executor GenServer: manages executor.uc compilation and path"
jj new
```

---

## Task 3: Add hashless POST /bytecode endpoint

**Files:**
- Modify: `lib/unex/api/bytecode_controller.ex`
- Modify: `lib/unex/api/router.ex`
- Modify: `test/unex/api/bytecode_api_test.exs`

Replace `POST /bytecode/:hash` (client-provided hash) with `POST /bytecode` (server-computed SHA256 hash).

- [ ] **Step 1: Replace `put/2` with `push/1` in BytecodeController**

In `lib/unex/api/bytecode_controller.ex`, replace the `put/2` function with:

```elixir
def push(conn) do
  with {:ok, body} <- Json.read_json(conn),
       %{"data" => hex} <- body,
       {:ok, bytes} <- Base.decode16(hex, case: :mixed) do
    hash = HashCache.put(HashCache, bytes)
    Json.send_json(conn, 201, %{hash: hash})
  else
    _ -> Json.send_json(conn, 400, %{error: "invalid_payload"})
  end
end
```

Note: `HashCache.put/2` (two-arg form) computes SHA256 and returns the hash string.

Remove the old `put/2` function and the `normalize_hash/1` helper (the `get/2` function still needs it — keep it if `get/2` uses it).

Actually, `get/2` still uses `normalize_hash/1` for the `#` stripping. Keep `normalize_hash/1` and `get/2` as-is. Only replace `put/2` with `push/1`.

- [ ] **Step 2: Update router**

In `lib/unex/api/router.ex`, replace the bytecode routes (around line 76-83):

```elixir
# Bytecode routes
post "/bytecode" do
  BytecodeController.push(conn)
end

get "/bytecode/:hash" do
  BytecodeController.get(conn, hash)
end
```

- [ ] **Step 3: Update bytecode API tests**

Read the existing test file first to understand the patterns, then update. The new `POST /bytecode` test should verify:
- POST with hex-encoded bytes returns 201 with a hash
- The hash is SHA256 of the raw bytes
- GET with that hash returns the bytes

- [ ] **Step 4: Run tests**

```bash
mix test test/unex/api/bytecode_api_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
jj desc -m "Replace POST /bytecode/:hash with hashless POST /bytecode (server-computed SHA256)"
jj new
```

---

## Task 4: Update Remote.do_execute to use executor

**Files:**
- Modify: `lib/unex/remote.ex`
- Modify: `test/unex/remote_test.exs`

Change `do_execute/2` to write the bundle to a temp file and run executor.uc instead of writing raw bytes as `.uc`.

- [ ] **Step 1: Update do_execute in remote.ex**

Replace `do_execute/2` (lines 56-72) with:

```elixir
def do_execute(hash, opts \\ []) do
  bundle_path = Path.join(System.tmp_dir!(), "unex_bundle_#{hash}.bin")

  with {:ok, executor_path} <- Unex.Executor.executor_path(),
       {:ok, resolved} <- SyncServer.resolve([hash]),
       data when is_binary(data) <- Map.get(resolved, hash) do
    try do
      File.write!(bundle_path, data)
      env = service_env() ++ [{"UNEX_BUNDLE", bundle_path}]
      Runner.run_compiled(executor_path, Keyword.merge(Keyword.take(opts, [:timeout, :args]), env: env))
    after
      File.rm(bundle_path)
    end
  else
    {:error, :not_compiled} -> {:error, :executor_not_available}
    {:error, _} = err -> err
    nil -> {:error, {:missing, hash}}
  end
end
```

- [ ] **Step 2: Update remote_test.exs**

The existing remote test stores raw `.uc` bytes compiled via `Compiler.compile`. With the executor, the stored data must be a valid bundle. For unit tests (without a real executor), test error paths:

```elixir
defmodule Unex.RemoteTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  setup do
    {:ok, _} = Unex.Cluster.HashCache.start_link(name: :remote_test_cache)
    {:ok, _} = Unex.Cluster.SyncServer.start_link(cache: :remote_test_cache, name: :remote_test_sync)

    on_exit(fn ->
      for name <- [:remote_test_cache, :remote_test_sync] do
        if pid = Process.whereis(name), do: GenServer.stop(pid)
      end
    end)

    :ok
  end

  test "execute with unknown hash returns error" do
    assert {:error, _} = Unex.Remote.execute("nonexistent_hash_abc123")
  end
end
```

Full integration testing of the executor flow is covered by the integration test in Task 8.

- [ ] **Step 3: Run tests**

```bash
mix test test/unex/remote_test.exs
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
jj desc -m "Update Remote.do_execute to use executor + bundle file"
jj new
```

---

## Task 5: Rewrite Services.u deploy handler

**Files:**
- Modify: `unison/Unex/Services.u`

Change the deploy ability to accept a function value and use Value + Code serialization.

- [ ] **Step 1: Rewrite Services.u**

Replace the entire file with:

```unison
-- Unex Services Ability
-- Deploy, call, list, undeploy, and release named services.
--
-- "deploy" takes a function value, serializes it as a Value+Code bundle, and pushes to the server.
-- This mirrors Unison Cloud's approach: pass the function directly, not a reference.
-- "release" points a service name at any existing hash (for versioning/rollback).

structural type Unex.ServiceInfo = { name : Text, hash : Text, node : Text }

unique ability Unex.Services where
  deploy : Text -> '{IO, Exception} () -> Text
  release : Text -> Text -> ()
  call : Text -> Text
  list : [Unex.ServiceInfo]
  undeploy : Text -> ()

Unex.Services.encodeU32 : Nat -> Bytes
Unex.Services.encodeU32 n =
  use Nat / mod
  Bytes.fromList [n / 16777216 `mod` 256, n / 65536 `mod` 256, n / 256 `mod` 256, n `mod` 256]

Unex.Services.gatherCode : [Link.Term] -> [(Link.Term, Bytes)]
Unex.Services.gatherCode deps =
  match deps with
    [] -> []
    d +: rest ->
      match Code.lookup d with
        Some code -> (d, Code.serialize code) +: Unex.Services.gatherCode rest
        None -> Unex.Services.gatherCode rest

Unex.Services.handler : Text -> Text -> Request {Unex.Services} a -> {IO, Exception, Http, Threads} a
Unex.Services.handler baseUrl secret = cases
  { Unex.Services.deploy name fn -> k } ->
    -- Serialize the function closure as a Value
    val = Value.value fn
    valBytes = Value.serialize val

    -- Gather all code dependencies
    deps = Value.dependencies val
    codePairs = Unex.Services.gatherCode deps

    -- Serialize the dependency list as a Value (only uses builtin types)
    depsVal = Value.value codePairs
    depsBytes = Value.serialize depsVal

    -- Build bundle: [4 bytes depsLen][depsBytes][valBytes]
    bundle = Unex.Services.encodeU32 (Bytes.size depsBytes) ++ depsBytes ++ valBytes

    -- Push bundle to server (hashless endpoint returns computed hash)
    resp = Unex.Http.postBytesJson secret (baseUrl ++ "/bytecode") bundle
    hash = match Unex.Http.extractField (bodyText resp) "hash" with
      Some h -> h
      None -> bug "Unex.Services.deploy: server did not return hash"

    handle k hash with Unex.Services.handler baseUrl secret

  { Unex.Services.release name hash -> k } ->
    _ = Unex.Http.postJson secret
          (baseUrl ++ "/services/" ++ name ++ "/release")
          (Unex.Http.toJson [("hash", hash)])
    handle k () with Unex.Services.handler baseUrl secret

  { Unex.Services.call name -> k } ->
    body = bodyText (Unex.Http.postEmpty secret (baseUrl ++ "/services/" ++ name ++ "/call"))
    handle k body with Unex.Services.handler baseUrl secret

  { Unex.Services.list -> k } ->
    _ = Unex.Http.getJson secret (baseUrl ++ "/services")
    handle k [] with Unex.Services.handler baseUrl secret

  { Unex.Services.undeploy name -> k } ->
    _ = Unex.Http.deleteReq secret (baseUrl ++ "/services/" ++ name)
    handle k () with Unex.Services.handler baseUrl secret

  { a } -> a
```

- [ ] **Step 2: Verify in UCM**

Load in a Unison project that has `@unison/base` and `@unison/http` installed:

```
myapp/main> load unison/Unex/Services.u
```

Expected: typechecks with no errors. If any API names are wrong (e.g., `Bytes.fromList`, `Code.serialize`, `Value.value`), fix them by checking with `find <name>` in UCM.

- [ ] **Step 3: Commit**

```bash
jj desc -m "Rewrite Services.u: Value+Code bundle deploy (Unison Cloud style)"
jj new
```

---

## Task 6: Update examples

**Files:**
- Modify: `test/example/service.u`
- Modify: `test/example/call.u`
- Remove: `test/example/deploy.u`

- [ ] **Step 1: Rewrite service.u as single-file deploy**

```unison
-- Example: Deploy a service using Value+Code serialization.
--
-- Everything in one file — no add, no termLink needed.
--
-- Workflow from UCM:
--   1. load test/example/service.u
--   2. run mainDeploy

myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  Unex.Storage.writeCell "svc" "hits" "0"
  printLine "Service started"

mainService : '{IO, Exception} ()
mainService = Unex.main myService

deployScript : '{Unex.Services, IO, Exception} ()
deployScript = do
  hash = Unex.Services.deploy "my-service" mainService
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)

mainDeploy : '{IO, Exception} ()
mainDeploy = Unex.main deployScript
```

- [ ] **Step 2: Update call.u**

```unison
callScript : '{Unex.Services, IO, Exception} ()
callScript = do
  result = Unex.Services.call "my-service"
  printLine result

main : '{IO, Exception} ()
main = Unex.main callScript
```

- [ ] **Step 3: Delete deploy.u**

```bash
rm test/example/deploy.u
```

- [ ] **Step 4: Commit**

```bash
jj desc -m "Update examples: single-file deploy, remove deploy.u"
jj new
```

---

## Task 7: Update documentation

**Files:**
- Modify: `docs/guide.md`
- Modify: `docs/api.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Rewrite guide Part 9 (Deploying services)**

Replace the current Part 9 in `docs/guide.md` (from `## Part 9: Deploying services` to the start of `## Part 10`) with:

```markdown
## Part 9: Deploying services

Services are named, long-running Unison programs callable from anywhere in the cluster. Deployment uses the same Value + Code serialization protocol as Unison Cloud — pass the function directly, and the platform handles the rest.

**Define and deploy — all in one file** (`service.u`):

\```unison
myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  Unex.Storage.writeCell "svc" "hits" "0"
  printLine "Service started"

-- Wrap with Unex.main so the server can inject credentials at runtime
mainService : '{IO, Exception} ()
mainService = Unex.main myService

app : '{Unex.Services, IO, Exception} ()
app = do
  hash = Unex.Services.deploy "my-service" mainService
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)

main : '{IO, Exception} ()
main = Unex.main app
\```

In UCM:
\```
myapp/main> load service.u
myapp/main> run main
\```

No `add` step. No `termLink`. One file, one load, one run. The `deploy` ability captures the function closure, serializes it with all its code dependencies, and ships it to the server.

**Calling a deployed service:**

\```unison
callApp : '{Unex.Services, IO, Exception} ()
callApp = do
  result = Unex.Services.call "my-service"
  printLine result

main : '{IO, Exception} ()
main = Unex.main callApp
\```

**Releasing a new version** — deploy new code, atomically update the name pointer:

\```unison
upgradeApp : '{Unex.Services, IO, Exception} ()
upgradeApp = do
  hash = Unex.Services.deploy "my-service" mainServiceV2
  Unex.Services.release "my-service" hash
  printLine ("Released v2: " ++ hash)
\```

**Rollback** — point the name back at any previous hash:

\```unison
rollback : '{Unex.Services, IO, Exception} ()
rollback = do
  Unex.Services.release "my-service" previousHash
\```

### How deployment works

Under the hood, `Unex.Services.deploy` uses the same protocol as Unison Cloud for distributing code:

1. `Value.value fn` — captures the runtime closure
2. `Value.serialize` — serializes it to bytes
3. `Value.dependencies` → `Code.lookup` → `Code.serialize` — gathers all code dependencies
4. The bundle (value + code) is pushed to the server via `POST /bytecode`
5. `release` points the service name at the bundle's content hash

When the service is called, the server runs an executor program that reverses this process: `Code.cache_` loads the dependencies, `Value.load` reconstitutes the function, and it runs with the server's credentials injected via environment variables.

Because credentials never appear in Unison code, all service definitions are safe to share on Unison Share.

### Server setup: executor

The server needs a compiled executor program to run deployed services. On first startup, it attempts to auto-compile from `unison/executor.u`. If auto-compilation fails (e.g., missing UCM or base library), compile manually:

\```
myapp/main> load unison/executor.u
myapp/main> add
myapp/main> compile executor data/executor.uc
\```

The executor only needs to be compiled once. The server caches it at `data/executor.uc`.
```

- [ ] **Step 2: Add Part 11 to guide — Publishing @kek/unex**

Append before or after the current "How it works" section (Part 10):

```markdown
## Part 11: Publishing @kek/unex updates

When the Unison ability files (`unison/Unex/*.u`, `unison/Main.u`) change, publish a new version of `@kek/unex` to Unison Share.

### Release workflow

1. **Open the library project in UCM:**
   \```
   ucm
   .> project.open kek/unex
   kek/unex/main>
   \```

2. **Load changed files and update definitions:**
   \```
   kek/unex/main> load unison/Unex/Services.u
   kek/unex/main> update
   kek/unex/main> load unison/Main.u
   kek/unex/main> update
   \```
   Repeat for each changed `.u` file. `update` replaces existing definitions.

3. **Verify:**
   \```
   kek/unex/main> test
   \```

4. **Create a release:**
   \```
   kek/unex/main> release.draft 0.2.0
   kek/unex/releases/0.2.0> push
   \```

5. **Users update:**
   \```
   myapp/main> lib.install @kek/unex
   \```

### When to release

- Ability signature changes (like `deploy` type change) — bump minor version
- Handler bug fixes — bump patch version
```

- [ ] **Step 3: Update api.md bytecode section**

Replace the Bytecode section in `docs/api.md` with:

```markdown
## Bytecode

Push and pull deployment bundles by content hash. Used by the deploy system.

\```bash
# Push a bundle (hex-encoded in JSON, server computes SHA256 hash)
curl -s -X POST localhost:4040/bytecode \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"data":"<hex-encoded-bundle-bytes>"}'
# Returns: {"hash":"<sha256>"}

# Pull a bundle by hash
curl -s -H "$AUTH" localhost:4040/bytecode/<hash> --output bundle.bin
\```

Bundles are created by the `Unex.Services.deploy` ability using Value + Code serialization. You typically don't interact with this endpoint directly.
```

- [ ] **Step 4: Update CLAUDE.md architecture sections**

Update the `### Execution flow` section to mention the executor:

```markdown
### Execution flow
`Unex.eval/2` and `Unex.compile_and_run/2` are the top-level API. Both create an ephemeral `Workspace` (isolated Unison codebase in tmp), then either run source directly via `Runner.run_file` or compile to `.uc` bytecode via `Compiler` first. Bytecode is cached in `HashCache` by SHA256. Deployed services use a different path: the client serializes a Value+Code bundle (Unison Cloud protocol), the server stores it in `HashCache`, and executes via a pre-compiled executor program (`executor.uc`) that loads the bundle at runtime.
```

Update the `### Abilities` intro to note the deploy change:

In the `### Unison ability library` section, add:

```markdown
`Services.u` uses Value+Code serialization for deployment — `Value.value`, `Value.serialize`, `Value.dependencies`, `Code.lookup`, `Code.serialize` — matching Unison Cloud's distributed execution protocol.
```

- [ ] **Step 5: Commit**

```bash
jj desc -m "Update docs: guide, API reference, and CLAUDE.md for Value+Code deployment"
jj new
```

---

## Task 8: Smoke test the full flow

This is a manual integration test to verify the POC works end-to-end.

- [ ] **Step 1: Compile the executor**

In a Unison project with `@unison/base` and `@kek/unex` installed:

```
myapp/main> load unison/executor.u
myapp/main> add
myapp/main> compile executor data/executor.uc
```

Verify: `data/executor.uc` exists.

- [ ] **Step 2: Start the server**

```bash
mix unex.start
```

- [ ] **Step 3: Load and run the deploy example**

In UCM (with UNEX_URL and UNEX_SECRET set):

```
myapp/main> load test/example/service.u
myapp/main> run mainDeploy
```

Expected: `Deployed: <hash>` (not an error).

- [ ] **Step 4: Call the deployed service**

```
myapp/main> load test/example/call.u
myapp/main> run main
```

Expected: stdout contains `Service started` (the output from `myService`).

- [ ] **Step 5: Run unit tests**

```bash
mix test --exclude integration
```

Expected: all pass.

---

## Notes for Implementation

**Unison API verification:** Before implementing Task 5, verify these builtins exist in your UCM version by running `find <name>` in UCM:
- `Value.value`
- `Value.serialize`
- `Value.deserialize`
- `Value.load`
- `Value.dependencies`
- `Code.lookup`
- `Code.serialize`
- `Code.deserialize`
- `Code.cache_`
- `Bytes.fromList`

If any name differs, adjust the Unison code accordingly.

**Bundle size:** For large services, the hex-encoded JSON body could be large. The default `Plug.Parsers` body limit is 8MB. If bundles exceed this, increase the limit in `router.ex`:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  json_decoder: Jason,
  length: 50_000_000,
  pass: ["application/octet-stream"]
```

This is an optimization concern — add it if you hit the limit during testing.

**`readFileBytes` in executor.u:** If `readFileBytes` is not available as a top-level function, try `IO.fileBytes.impl` or build it from `IO.openFile` + `Handle.getBytes` + `Handle.closeFile`. Check with `find readFile` in UCM.
