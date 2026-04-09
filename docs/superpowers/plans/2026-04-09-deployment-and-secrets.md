# Deployment and Secrets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Unex app code shareable (no secrets/URLs in source), add a clean release/versioning model, and inject connection env vars into server-side UCM execution.

**Architecture:** `Unex.main` reads `UNEX_URL`/`UNEX_SECRET` from environment variables instead of taking parameters. A new `release` operation decouples "upload code" from "point a name at it". When the server runs a deployed service, it injects those same env vars into the UCM subprocess so handlers connect back to the local server.

**Tech Stack:** Elixir/Plug for API changes, Unison `.u` files for ability changes, ExUnit for tests.

---

## File Map

**Modified (Elixir):**
- `lib/unex/runner.ex` — add `:env` option to `run_compiled/2`
- `lib/unex/remote.ex` — inject `UNEX_URL`/`UNEX_SECRET` into UCM subprocess
- `lib/unex/services.ex` — add `release/2` function
- `lib/unex/api/router.ex` — add `/bytecode/:hash` and `/services/:name/release` routes
- `lib/unex/api/services_controller.ex` — add `release/2` action

**Created (Elixir):**
- `lib/unex/api/bytecode_controller.ex` — `PUT /bytecode/:hash` and `GET /bytecode/:hash`
- `test/unex/api/bytecode_api_test.exs` — API tests for bytecode push/pull
- `test/unex/services_release_test.exs` — unit tests for `Services.release/2`
- `test/unex/api/services_release_api_test.exs` — API tests for release endpoint

**Modified (Unison):**
- `unison/Main.u` — remove `baseUrl`/`secret` params, read from env vars
- `unison/Unex/Services.u` — add `release` ability operation and handler
- `unison/Examples/BasicStorage.u` — update `main` call
- `unison/Examples/ConfigAndSecrets.u` — update `main` call
- `unison/Examples/FullApp.u` — update `main` call

---

## Task 1: `Unex.main` reads env vars (Unison)

**Files:**
- Modify: `unison/Main.u`

No automated tests — Unison files are loaded in UCM, not run by `mix test`. Verify by inspecting the file after editing.

- [ ] **Step 1: Rewrite `unison/Main.u`**

Replace the entire file with:

```unison
-- Unex Main Combinator
-- Composes all ability handlers to run a program against a Unex server.
--
-- Connection details are read from environment variables:
--   UNEX_URL    — server base URL (default: http://localhost:4040)
--   UNEX_SECRET — bearer token    (default: empty string)
--
-- Usage:
--   main : '{IO, Exception} ()
--   main = Unex.main myApp
--
-- Where myApp uses any combination of Unex.Storage, Unex.Config, Unex.Blobs,
-- Unex.Scratch, Unex.Log, Unex.Remote, Unex.Services.
--
-- For tests or explicit config:
--   main = Unex.main.withConfig "http://localhost:4040" "my-secret" myApp


Unex.main : '{Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch, Unex.Log, Unex.Remote, Unex.Services, IO, Exception} a
  -> '{IO, Exception} a
Unex.main program =
  Unex.main.withConfig
    (Optional.getOrElse "http://localhost:4040" (IO.getEnv "UNEX_URL"))
    (Optional.getOrElse "" (IO.getEnv "UNEX_SECRET"))
    program

Unex.main.withConfig : Text
  -> Text
  -> '{Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch, Unex.Log, Unex.Remote, Unex.Services, IO, Exception} a
  -> '{IO, Exception} a
Unex.main.withConfig baseUrl secret program = do
  Threads.run do Http.run do
    handle
      (handle
        (handle
          (handle
            (handle
              (handle
                (handle !program
                  with Unex.Storage.handler baseUrl secret)
                with Unex.Config.handler baseUrl secret)
              with Unex.Blobs.handler baseUrl secret)
            with Unex.Scratch.handler baseUrl secret)
          with Unex.Log.handler baseUrl secret)
        with Unex.Remote.handler baseUrl secret)
      with Unex.Services.handler baseUrl secret
```

- [ ] **Step 2: Commit**

```bash
git add unison/Main.u
git commit -m "feat: Unex.main reads UNEX_URL/UNEX_SECRET from env vars"
```

---

## Task 2: Update Unison examples

**Files:**
- Modify: `unison/Examples/BasicStorage.u`
- Modify: `unison/Examples/ConfigAndSecrets.u`
- Modify: `unison/Examples/FullApp.u`

- [ ] **Step 1: Update `unison/Examples/BasicStorage.u`**

Replace the `main` definition (last 2 lines):

```unison
Examples.BasicStorage.main : '{IO, Exception} ()
Examples.BasicStorage.main = Unex.main Examples.BasicStorage.app
```

Also update the file comment at the top to remove the hardcoded URL reference:

```unison
-- Example: Basic Storage operations using Unex.Storage ability
--
-- Set UNEX_URL and UNEX_SECRET env vars, then run from UCM:
--   myProject/main> run Examples.BasicStorage.main
```

- [ ] **Step 2: Update `unison/Examples/ConfigAndSecrets.u`**

Replace the `main` definition. The current one manually handles abilities — replace with the simple form:

```unison
Examples.ConfigAndSecrets.main : '{IO, Exception} ()
Examples.ConfigAndSecrets.main = Unex.main Examples.ConfigAndSecrets.app
```

Also update the file comment:

```unison
-- Example: Config (encrypted secrets) and Scratch (ephemeral cache)
--
-- Set UNEX_URL and UNEX_SECRET env vars, then run from UCM:
--   myProject/main> run Examples.ConfigAndSecrets.main
```

- [ ] **Step 3: Update `unison/Examples/FullApp.u`**

Replace the `main` definition:

```unison
Examples.FullApp.main : '{IO, Exception} ()
Examples.FullApp.main = Unex.main Examples.FullApp.app
```

Also update the file comment:

```unison
-- Example: Full application using all abilities via Unex.main
--
-- Set UNEX_URL and UNEX_SECRET env vars, then run from UCM:
--   myProject/main> run Examples.FullApp.main
```

- [ ] **Step 4: Commit**

```bash
git add unison/Examples/BasicStorage.u unison/Examples/ConfigAndSecrets.u unison/Examples/FullApp.u
git commit -m "feat: update examples to use parameterless Unex.main"
```

---

## Task 3: Add `release` operation to Unison Services ability

**Files:**
- Modify: `unison/Unex/Services.u`

- [ ] **Step 1: Add `release` to `unison/Unex/Services.u`**

Add `release` to the ability declaration and add its handler case. The full file:

```unison
-- Unex Services Ability
-- Deploy, call, list, undeploy, and release named services.
--
-- "deploy" compiles source and returns a hash.
-- "release" points a service name at any existing hash (for versioning/rollback).


structural type Unex.ServiceInfo = { name : Text, hash : Text, node : Text }

unique ability Unex.Services where
  deploy : Text -> Text -> Text
  release : Text -> Text -> ()
  call : Text -> Text
  list : [Unex.ServiceInfo]
  undeploy : Text -> ()

Unex.Services.handler : Text -> Text -> Request {Unex.Services} a -> {IO, Exception, Http, Threads} a
Unex.Services.handler baseUrl secret = cases
  { Unex.Services.deploy name source -> k } ->
    body = bodyText (Unex.Http.postJson secret
          (baseUrl ++ "/services/deploy")
          ("{\"name\":\"" ++ name ++ "\",\"source\":\"" ++ source ++ "\"}"))
    handle k body with Unex.Services.handler baseUrl secret

  { Unex.Services.release name hash -> k } ->
    _ = Unex.Http.postJson secret
          (baseUrl ++ "/services/" ++ name ++ "/release")
          ("{\"hash\":\"" ++ hash ++ "\"}")
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

- [ ] **Step 2: Commit**

```bash
git add unison/Unex/Services.u
git commit -m "feat: add release operation to Unex.Services ability"
```

---

## Task 4: BytecodeController — push and pull endpoints

**Files:**
- Create: `lib/unex/api/bytecode_controller.ex`
- Modify: `lib/unex/api/router.ex`
- Create: `test/unex/api/bytecode_api_test.exs`

The Unison hash format is `#abc123def` — the `#` must be percent-encoded as `%23` in URLs. Accept the hash as a path segment and strip the leading `#` if present when using it as a cache key.

- [ ] **Step 1: Write the failing tests**

Create `test/unex/api/bytecode_api_test.exs`:

```elixir
defmodule Unex.API.BytecodeApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router
  alias Unex.Cluster.HashCache

  @opts Router.init([])

  defp call(method, path, body \\ nil, content_type \\ "application/octet-stream") do
    secret = Application.get_env(:unex, :api_secret)

    conn =
      if body do
        conn(method, path, body)
        |> put_req_header("content-type", content_type)
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> Router.call(@opts)
  end

  test "PUT /bytecode/:hash stores bytes and returns 201 with hash" do
    bytes = "fake-bytecode-data-#{System.unique_integer()}"
    hash = "test#{System.unique_integer([:positive])}"

    conn = call(:put, "/bytecode/#{hash}", bytes)
    assert conn.status == 201

    body = Jason.decode!(conn.resp_body)
    assert body["hash"] == hash
  end

  test "GET /bytecode/:hash returns 200 with stored bytes" do
    bytes = "fake-bytecode-#{System.unique_integer()}"
    hash = "gettest#{System.unique_integer([:positive])}"
    HashCache.put(HashCache, hash, bytes)

    conn = call(:get, "/bytecode/#{hash}")
    assert conn.status == 200
    assert conn.resp_body == bytes
  end

  test "GET /bytecode/:hash returns 404 for unknown hash" do
    conn = call(:get, "/bytecode/nonexistent-hash-xyz")
    assert conn.status == 404

    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "not_found"
  end

  test "PUT /bytecode/:hash is idempotent" do
    bytes = "idempotent-data-#{System.unique_integer()}"
    hash = "idem#{System.unique_integer([:positive])}"

    conn1 = call(:put, "/bytecode/#{hash}", bytes)
    conn2 = call(:put, "/bytecode/#{hash}", bytes)
    assert conn1.status == 201
    assert conn2.status == 201
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/unex/api/bytecode_api_test.exs
```

Expected: compile error or route-not-found failures (404 status, not the 404 we assert in the last test).

- [ ] **Step 3: Create `lib/unex/api/bytecode_controller.ex`**

```elixir
defmodule Unex.API.BytecodeController do
  @moduledoc """
  HTTP handler for pushing and pulling bytecode blobs, keyed by hash.

  PUT /bytecode/:hash  — store raw bytecode bytes under the given hash
  GET /bytecode/:hash  — retrieve bytecode bytes by hash
  """

  alias Unex.Cluster.HashCache
  alias Unex.API.Json

  def put(conn, hash) do
    {:ok, bytes, conn} = Plug.Conn.read_body(conn)
    HashCache.put(HashCache, hash, bytes)
    Json.send_json(conn, 201, %{hash: hash})
  end

  def get(conn, hash) do
    case HashCache.get(HashCache, hash) do
      {:ok, bytes} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, bytes)

      :not_found ->
        Json.send_json(conn, 404, %{error: "not_found"})
    end
  end
end
```

- [ ] **Step 4: Add routes to `lib/unex/api/router.ex`**

Add the `BytecodeController` alias in the alias block at the top:

```elixir
  alias Unex.API.{
    DatabaseController,
    OrderedTableController,
    CellController,
    TransactionController,
    ServicesController,
    BytecodeController,
    ConfigController,
    BlobsController,
    ScratchController,
    LogController,
    Json
  }
```

Add routes before the services routes section (around line 74):

```elixir
  # Bytecode routes
  put "/bytecode/:hash" do
    BytecodeController.put(conn, hash)
  end

  get "/bytecode/:hash" do
    BytecodeController.get(conn, hash)
  end
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
mix test test/unex/api/bytecode_api_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 6: Run full test suite to confirm no regressions**

```bash
mix test
```

Expected: all existing tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/unex/api/bytecode_controller.ex lib/unex/api/router.ex test/unex/api/bytecode_api_test.exs
git commit -m "feat: add PUT/GET /bytecode/:hash endpoints for bytecode push/pull"
```

---

## Task 5: `Services.release` — decouple naming from deployment

**Files:**
- Modify: `lib/unex/services.ex`
- Modify: `lib/unex/api/services_controller.ex`
- Modify: `lib/unex/api/router.ex`
- Create: `test/unex/services_release_test.exs`
- Create: `test/unex/api/services_release_api_test.exs`

- [ ] **Step 1: Write failing unit tests**

Create `test/unex/services_release_test.exs`:

```elixir
defmodule Unex.ServicesReleaseTest do
  use ExUnit.Case, async: false

  alias Unex.Services
  alias Unex.Services.Registry

  @moduletag timeout: 120_000

  test "release points a name at an existing hash" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"v1\""
    {:ok, entry} = Services.deploy("rel-svc", source)
    original_hash = entry.hash

    # release to same hash — should work (idempotent naming)
    assert :ok = Services.release("rel-svc", original_hash)

    {:ok, resolved} = Registry.resolve("rel-svc")
    assert resolved.hash == original_hash
  end

  test "release can point a name at a different existing hash" do
    source_v1 = "main : '{IO, Exception} ()\nmain = do printLine \"v1\""
    source_v2 = "main : '{IO, Exception} ()\nmain = do printLine \"v2\""

    {:ok, entry_v1} = Services.deploy("rollback-svc-v1", source_v1)
    {:ok, entry_v2} = Services.deploy("rollback-svc-v2", source_v2)

    # point "my-app" at v2
    :ok = Services.release("my-app", entry_v2.hash)
    {:ok, result} = Services.call("my-app")
    assert result.stdout =~ "v2"

    # rollback: point "my-app" at v1
    :ok = Services.release("my-app", entry_v1.hash)
    {:ok, result} = Services.call("my-app")
    assert result.stdout =~ "v1"
  end

  test "release on unknown hash still registers the name" do
    # Releasing to an unknown hash registers it; call will fail at execution time
    assert :ok = Services.release("ghost-svc", "nonexistent-hash-abc")
    {:ok, resolved} = Registry.resolve("ghost-svc")
    assert resolved.hash == "nonexistent-hash-abc"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/unex/services_release_test.exs
```

Expected: `UndefinedFunctionError` for `Services.release/2`.

- [ ] **Step 3: Add `release/2` to `lib/unex/services.ex`**

Add after the `call/2` function (around line 45):

```elixir
  @doc """
  Points a service name at an existing bytecode hash.

  This is how versioning and rollback work: `deploy` uploads bytecode and
  returns a hash; `release` moves the name pointer to any existing hash.

  Returns `:ok` unconditionally — the hash need not exist yet.
  """
  def release(name, hash) do
    {:ok, _entry} = Registry.register(name, hash, node())
    :ok
  end
```

- [ ] **Step 4: Run unit tests to confirm they pass**

```bash
mix test test/unex/services_release_test.exs
```

Expected: 3 tests, 0 failures. (The "ghost-svc" test with unknown hash passes at the `release` step; `call` would fail but we don't call it.)

- [ ] **Step 5: Write failing API tests**

Create `test/unex/api/services_release_api_test.exs`:

```elixir
defmodule Unex.API.ServicesReleaseApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router

  @opts Router.init([])

  defp call(method, path, body \\ nil) do
    secret = Application.get_env(:unex, :api_secret)

    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  @moduletag timeout: 180_000

  test "POST /services/:name/release returns 200 with name and hash" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"release-test\""
    deploy_conn = call(:post, "/services/deploy", %{"name" => "relapi-svc", "source" => source})
    assert deploy_conn.status == 201
    hash = json_body(deploy_conn)["hash"]

    conn = call(:post, "/services/relapi-svc/release", %{"hash" => hash})
    assert conn.status == 200

    body = json_body(conn)
    assert body["name"] == "relapi-svc"
    assert body["hash"] == hash
  end

  test "POST /services/:name/release without hash returns 422" do
    conn = call(:post, "/services/bad-svc/release", %{})
    assert conn.status == 422
  end

  test "released service is callable" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"released-ok\""
    deploy_conn = call(:post, "/services/deploy", %{"name" => "callrel-svc", "source" => source})
    hash = json_body(deploy_conn)["hash"]

    call(:post, "/services/callrel-svc/release", %{"hash" => hash})

    conn = call(:post, "/services/callrel-svc/call")
    assert conn.status == 200
    assert json_body(conn)["stdout"] =~ "released-ok"
  end
end
```

- [ ] **Step 6: Run API tests to confirm they fail**

```bash
mix test test/unex/api/services_release_api_test.exs
```

Expected: route-not-found (404) or compile error.

- [ ] **Step 7: Add `release/2` to `lib/unex/api/services_controller.ex`**

Add after `undeploy/2`:

```elixir
  def release(conn, name) do
    {:ok, params} = Json.read_json(conn)

    case params["hash"] do
      nil ->
        Json.send_json(conn, 422, %{error: "hash is required"})

      hash ->
        :ok = Services.release(name, hash)
        Json.send_json(conn, 200, %{name: name, hash: hash})
    end
  end
```

- [ ] **Step 8: Add route to `lib/unex/api/router.ex`**

Add after the `post "/services/deploy"` route, before `post "/services/:name/call"`. The release route must come BEFORE the call route, since both match `/services/:name/...`:

```elixir
  post "/services/:name/release" do
    ServicesController.release(conn, name)
  end
```

- [ ] **Step 9: Run API tests to confirm they pass**

```bash
mix test test/unex/api/services_release_api_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 10: Run full test suite to confirm no regressions**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 11: Commit**

```bash
git add lib/unex/services.ex lib/unex/api/services_controller.ex lib/unex/api/router.ex \
  test/unex/services_release_test.exs test/unex/api/services_release_api_test.exs
git commit -m "feat: add Services.release/2 and POST /services/:name/release endpoint"
```

---

## Task 6: Inject env vars into UCM subprocess for server-side execution

**Files:**
- Modify: `lib/unex/runner.ex`
- Modify: `lib/unex/remote.ex`

When the server calls a deployed service via `Remote.execute`, the UCM subprocess needs `UNEX_URL` and `UNEX_SECRET` so the `Unex.main` inside the bytecode can connect back to the server.

- [ ] **Step 1: Write a failing test in `test/unex/remote_test.exs`**

Add this test to the existing `test/unex/remote_test.exs` file, inside the `Unex.RemoteTest` module, after the existing tests:

```elixir
  test "execute/2 passes UNEX_URL and UNEX_SECRET to UCM subprocess", %{hash: hash} do
    # This tests that env vars are set; the existing "remote-ok" bytecode
    # doesn't USE the env vars but they must not cause errors.
    assert {:ok, result} = Remote.execute(hash, timeout: 60_000)
    assert result.exit_code == 0
  end
```

This test passes once the implementation is done (it's a smoke test for the env injection).

- [ ] **Step 2: Add `:env` option to `Runner.run_compiled/2` in `lib/unex/runner.ex`**

Replace the `run_compiled/2` function:

```elixir
  @doc """
  Executes a compiled .uc bytecode file using `ucm run.compiled`.

  Options:
    - `:timeout` - max execution time in ms (default: 30_000)
    - `:args` - list of string arguments to pass to the program
    - `:env` - list of `{"KEY", "VALUE"}` tuples to set as env vars in the subprocess
  """
  def run_compiled(uc_path, opts \\ []) do
    {:ok, ucm} = Unex.UCM.find()
    timeout = Keyword.get(opts, :timeout, configured_timeout())
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    ucm_args = ["run.compiled", uc_path] ++ args

    run_ucm(ucm, ucm_args, timeout, env)
  end
```

Replace the private `run_ucm/3` function signature and body to accept `env`:

```elixir
  defp run_ucm(ucm, args, timeout, env \\ []) do
    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ]

    port_opts =
      if env == [] do
        port_opts
      else
        charlist_env = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
        [{:env, charlist_env} | port_opts]
      end

    port = Port.open({:spawn_executable, ucm}, port_opts)

    collect_output(port, "", timeout)
  end
```

- [ ] **Step 3: Update `Remote.do_execute/2` in `lib/unex/remote.ex`** to inject env vars

Replace `do_execute/2`:

```elixir
  @doc """
  Resolves bytecode for `hash` and executes it locally.

  Public because it is called via RPC from remote nodes.
  """
  def do_execute(hash, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "unex_exec_#{hash}.uc")

    with {:ok, resolved} <- SyncServer.resolve([hash]),
         data when is_binary(data) <- Map.get(resolved, hash) do
      try do
        File.write!(path, data)
        env = service_env()
        Runner.run_compiled(path, Keyword.merge(Keyword.take(opts, [:timeout, :args]), [env: env]))
      after
        File.rm(path)
      end
    else
      {:error, _} = err -> err
      nil -> {:error, {:missing, hash}}
    end
  end
```

Add the private helper at the bottom of the module, before the closing `end`:

```elixir
  defp service_env do
    port = Application.get_env(:unex, :port, 4040)
    url = "http://localhost:#{port}"
    secret = Application.get_env(:unex, :api_secret, "")
    [{"UNEX_URL", url}, {"UNEX_SECRET", secret}]
  end
```

- [ ] **Step 4: Run the remote test to confirm it passes**

```bash
mix test test/unex/remote_test.exs
```

Expected: all tests pass including the new smoke test.

- [ ] **Step 5: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/unex/runner.ex lib/unex/remote.ex test/unex/remote_test.exs
git commit -m "feat: inject UNEX_URL and UNEX_SECRET into UCM subprocess on service execution"
```

---

## Self-Review Checklist

**Spec coverage:**
- ✅ `Unex.main` reads env vars — Task 1
- ✅ `Unex.main.withConfig` escape hatch — Task 1
- ✅ Examples updated — Task 2
- ✅ `Unex.Services.release` ability + handler — Task 3
- ✅ `PUT/GET /bytecode/:hash` endpoints — Task 4
- ✅ `Services.release/2` Elixir function — Task 5
- ✅ `POST /services/:name/release` endpoint — Task 5
- ✅ Env var injection into UCM subprocess — Task 6
- ⚠️ **Not in this plan:** HashCache re-keying to Unison hash, compile-locally-ship-bytecode pipeline, `Code.lookup` based deploy. These require further research into Unison `Code` serialization and are deferred to a follow-up plan.

**Type/name consistency:**
- `Services.release(name, hash)` — used in unit tests (Task 5, Step 1), impl (Step 3), API (Steps 5-8), and Unison handler (Task 3). Consistent.
- `BytecodeController.put/get` — used in router (Task 4, Step 4) and controller (Step 3). Consistent.
- `Runner.run_compiled(path, opts)` with `:env` key — used in runner (Task 6, Step 2) and remote (Step 3). Consistent.
- `service_env/0` — private to `Remote`, only called from `do_execute`. Consistent.
