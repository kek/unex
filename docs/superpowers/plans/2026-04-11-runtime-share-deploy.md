# Runtime + Share Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace manual client-side `ucm compile` with server-side compilation via a persistent codebase that pulls from Unison Share.

**Architecture:** `Unex.Runtime` GenServer manages a persistent UCM codebase. On deploy, the client sends the Unison Share project name + entry point hash. The server pulls from Share into its codebase, compiles the entry point to `.uc`, stores in HashCache, and registers the service. Execution uses `ucm run.compiled` as before.

**Tech Stack:** Elixir/BEAM, UCM interactive mode via Port, Unison Share.

---

## File Map

**Create:**
- `lib/unex/runtime.ex` — GenServer: persistent codebase, pull + compile

**Modify:**
- `lib/unex/api/services_controller.ex` — Add `deploy/2` handler
- `lib/unex/api/router.ex` — Add `POST /services/:name/deploy` route
- `lib/unex/services.ex` — Add `deploy/2` function
- `lib/unex/application.ex` — Replace Executor with Runtime in supervision tree
- `lib/unex/remote.ex` — Remove Executor dependency (already done in POC, verify)
- `unison/Unex/Services.u` — Deploy sends hash + project to new endpoint
- `test/example/service.u` — Back to two-file with add + push
- `test/example/deploy.u` — Recreated with termLink deploy
- `docs/guide.md` — Updated deploy workflow
- `CLAUDE.md` — Updated architecture

**Remove:**
- `lib/unex/executor.ex` — Replaced by Runtime
- `unison/executor.u` — No longer needed

---

## Task 1: Create Unex.Runtime GenServer

**Files:**
- Create: `lib/unex/runtime.ex`
- Modify: `lib/unex/application.ex`

- [ ] **Step 1: Create lib/unex/runtime.ex**

```elixir
defmodule Unex.Runtime do
  @moduledoc """
  Manages a persistent UCM codebase for server-side compilation.

  On deploy, pulls a project from Unison Share into the local codebase,
  compiles the entry point to .uc bytecode, and returns the bytes.
  """

  use GenServer

  require Logger

  @compile_timeout 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pulls a project from Unison Share and compiles an entry point.

  Returns `{:ok, uc_bytes}` or `{:error, reason}`.
  """
  def compile(server \\ __MODULE__, project, hash) do
    GenServer.call(server, {:compile, project, hash}, @compile_timeout)
  end

  @impl true
  def init(_opts) do
    codebase_path = Path.join(data_dir(), "runtime")
    unison_path = Path.join(codebase_path, ".unison")

    unless File.dir?(unison_path) do
      Logger.info("Runtime: initializing codebase at #{codebase_path}")
      File.mkdir_p!(codebase_path)
      init_codebase(codebase_path)
    end

    Logger.info("Runtime: codebase ready at #{codebase_path}")
    {:ok, %{codebase_path: codebase_path}}
  end

  @impl true
  def handle_call({:compile, project, hash}, _from, state) do
    result = do_compile(state.codebase_path, project, hash)
    {:reply, result, state}
  end

  defp do_compile(codebase_path, project, hash) do
    {:ok, ucm} = Unex.UCM.find()
    unison_path = Path.join(codebase_path, ".unison")
    output_path = Path.join(System.tmp_dir!(), "unex_compile_#{hash}")

    commands = "pull #{project} .deployments.h#{hash}\ncompile .deployments.h#{hash} #{output_path}\nexit\n"

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase", unison_path],
        cd: codebase_path
      ])

    send(port, {self(), {:command, commands}})
    output = collect_output(port, "", @compile_timeout)

    uc_file = output_path <> ".uc"

    cond do
      Unex.UCM.Output.error?(output) ->
        {:error, output}

      File.exists?(uc_file) ->
        bytes = File.read!(uc_file)
        File.rm(uc_file)
        {:ok, bytes}

      true ->
        {:error, "Compilation produced no output. UCM output: #{output}"}
    end
  end

  defp init_codebase(codebase_path) do
    {:ok, ucm} = Unex.UCM.find()
    unison_path = Path.join(codebase_path, ".unison")

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase-create", unison_path],
        cd: codebase_path
      ])

    commands = "project.create runtime\nlib.install @unison/base\nlib.install @unison/http\nlib.install @kek/unex\nexit\n"
    send(port, {self(), {:command, commands}})
    collect_output(port, "", @compile_timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, _code}} ->
        acc
    after
      timeout ->
        Port.close(port)
        acc
    end
  end

  defp data_dir do
    Application.get_env(:unex, :data_dir, "data")
  end
end
```

- [ ] **Step 2: Replace Executor with Runtime in supervision tree**

In `lib/unex/application.ex`, change `Unex.Executor` to `Unex.Runtime` in the `cluster_children/0` list:

```elixir
defp cluster_children do
  [
    Unex.Cluster.HashCache,
    Unex.Cluster.SyncServer,
    Unex.Services.Registry,
    Unex.Abilities.Scratch,
    Unex.Abilities.Log,
    Unex.Runtime
  ]
end
```

- [ ] **Step 3: Verify it compiles**

```bash
mix compile
```

Expected: no errors. Runtime init will log "initializing codebase" on first run.

- [ ] **Step 4: Commit**

```bash
jj new && jj desc -m "Add Runtime GenServer: persistent codebase with pull + compile"
```

---

## Task 2: Add deploy endpoint

**Files:**
- Modify: `lib/unex/api/services_controller.ex`
- Modify: `lib/unex/api/router.ex`
- Modify: `lib/unex/services.ex`

- [ ] **Step 1: Add deploy/2 to Services module**

In `lib/unex/services.ex`, add after the `undeploy/1` function:

```elixir
@doc """
Deploys a service by pulling from Unison Share and compiling.

The `project` is a Share project reference (e.g., "@myorg/myapp").
The `hash` is the Unison hash of the entry point term.

Returns `{:ok, %Entry{}}` on success.
"""
def deploy(name, project, hash) do
  case Unex.Runtime.compile(project, hash) do
    {:ok, uc_bytes} ->
      storage_hash = Unex.Cluster.HashCache.put(HashCache, uc_bytes)
      release(name, storage_hash)

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 2: Add deploy/2 to ServicesController**

In `lib/unex/api/services_controller.ex`, add after the `release/2` function:

```elixir
def deploy(conn, name) do
  {:ok, params} = Json.read_json(conn)

  with hash when is_binary(hash) <- params["hash"],
       project when is_binary(project) <- params["project"] do
    case Services.deploy(name, project, hash) do
      {:ok, entry} ->
        Json.send_json(conn, 200, %{name: name, hash: entry.hash})

      {:error, reason} ->
        Json.send_json(conn, 500, %{error: inspect(reason)})
    end
  else
    _ -> Json.send_json(conn, 422, %{error: "hash and project are required"})
  end
end
```

- [ ] **Step 3: Add route**

In `lib/unex/api/router.ex`, add before the existing `post "/services/:name/release"` route:

```elixir
post "/services/:name/deploy" do
  ServicesController.deploy(conn, name)
end
```

- [ ] **Step 4: Verify it compiles**

```bash
mix compile
```

- [ ] **Step 5: Commit**

```bash
jj new && jj desc -m "Add POST /services/:name/deploy endpoint (pull + compile)"
```

---

## Task 3: Rewrite Services.u and examples

**Files:**
- Modify: `unison/Unex/Services.u`
- Modify: `test/example/service.u`
- Create: `test/example/deploy.u`

- [ ] **Step 1: Rewrite Services.u**

Replace entire content of `unison/Unex/Services.u`:

```unison
-- Unex Services Ability
-- Deploy, call, list, undeploy, and release named services.
--
-- "deploy" takes a Link.Term, sends the hash + Share project to the server.
-- The server pulls from Share, compiles to .uc, and stores the bytecode.
-- "release" points a service name at any existing hash (for versioning/rollback).

structural type Unex.ServiceInfo = { name : Text, hash : Text, node : Text }

unique ability Unex.Services where
  deploy : Text -> Link.Term -> Text
  release : Text -> Text -> ()
  call : Text -> Text
  list : [Unex.ServiceInfo]
  undeploy : Text -> ()

Unex.Services.handler : Text -> Text -> Request {Unex.Services} a -> {IO, Exception, Http, Threads} a
Unex.Services.handler baseUrl secret = cases
  { Unex.Services.deploy name link -> k } ->
    raw = Link.Term.toText link
    hash = if Text.take 1 raw == "#" then Text.drop 1 raw else raw
    project = match catch do IO.getEnv "UNEX_PROJECT" with
      Left _ -> bug "Unex.Services.deploy: UNEX_PROJECT env var not set"
      Right p -> p
    resp = Unex.Http.postJson secret
      (baseUrl ++ "/services/" ++ name ++ "/deploy")
      (Unex.Http.toJson [("hash", hash), ("project", project)])
    deployHash = match Unex.Http.extractField (bodyText resp) "hash" with
      Some h -> h
      None -> bug "Unex.Services.deploy: server did not return hash"
    handle k deployHash with Unex.Services.handler baseUrl secret

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

- [ ] **Step 2: Rewrite service.u example**

Replace `test/example/service.u`:

```unison
-- Step 1: Define and add the service.
--
-- Workflow from UCM:
--   1. load test/example/service.u
--   2. add
--   3. push
--   4. load test/example/deploy.u
--   5. run mainDeploy

myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  Unex.Storage.writeCell "svc" "hits" "0"
  printLine "Service started"

mainService : '{IO, Exception} ()
mainService = Unex.main myService
```

- [ ] **Step 3: Create deploy.u example**

Create `test/example/deploy.u`:

```unison
deployScript : '{Unex.Services, IO, Exception} ()
deployScript = do
  hash = Unex.Services.deploy "my-service" (termLink mainService)
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)

mainDeploy : '{IO, Exception} ()
mainDeploy = Unex.main deployScript
```

- [ ] **Step 4: Commit**

```bash
jj new && jj desc -m "Rewrite Services.u: server-side compile via Share pull"
```

---

## Task 4: Clean up and update docs

**Files:**
- Remove: `lib/unex/executor.ex`
- Remove: `unison/executor.u`
- Modify: `docs/guide.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Remove executor files**

```bash
rm lib/unex/executor.ex unison/executor.u
```

- [ ] **Step 2: Update guide Part 9**

In `docs/guide.md`, replace Part 9 (Deploying services) with the Share-based workflow:

- Setup: `export UNEX_PROJECT=@myorg/myapp`
- Workflow: `load` → `add` → `push` → `run mainDeploy`
- Server pulls from Share and compiles automatically
- No manual `compile` step
- Executor section removed

- [ ] **Step 3: Update CLAUDE.md execution flow**

Update the execution flow section to mention Runtime + Share pull instead of executor.

- [ ] **Step 4: Verify tests pass**

```bash
mix test --exclude integration
```

- [ ] **Step 5: Commit**

```bash
jj new && jj desc -m "Remove executor, update docs for Share-based deploy"
```

---

## Notes

**UCM pull syntax:** The plan uses `pull @myorg/myapp .deployments.h{hash}`. The exact syntax may need adjustment — UCM's `pull` expects a remote path and a local destination. Verify with `help pull` in UCM. If the syntax differs, adjust the `do_compile` commands string in Runtime.

**UCM compile by hash:** The plan uses `compile .deployments.h{hash} output`. If UCM can't compile by namespace path, use the hash directly: `compile #hash output`. Test both forms.

**First deploy is slow:** The Runtime's `init_codebase` installs base libraries (~30-60s). Subsequent deploys only pull + compile (~5-10s). The codebase persists across server restarts.
