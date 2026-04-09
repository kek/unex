# Service Deploy by Value Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace source-text service deployment with Code-lookup-based deployment: the client uses `Code.lookup (termLink program)` to get compiled bytecode, pushes it to the server via `PUT /bytecode/:hash` keyed by Unison hash, and the server runs it with `ucm run.compiled`. The service thunk is pre-wrapped with `Unex.main` on the client so all ability handlers and env-var connection details are baked into the pushed bytecode.

**Architecture:** The `deploy` ability changes from `deploy : Text -> Text -> Text` (name, source → hash) to `deploy : Text -> Link.Term -> Text` (name, termLink → hash). The handler calls `Code.lookup link` to retrieve compiled bytecode from the running Unison runtime, serializes it with `Code.serialize_v3`, and pushes to `PUT /bytecode/<unison-hash>`. The server is unchanged for execution: `Remote.do_execute` still fetches bytes from HashCache by hash and runs `ucm run.compiled`. No executor program, no ValueDeps store, no server-side compilation.

**Tech Stack:** Elixir/BEAM, Unison (lib.base.reflection.Code, lib.unison_http), UCM subprocess.

---

## File Map

**Modify:**
- `unison/Unex/Http/Helpers.u` — add `putBytes` helper (raw binary PUT)
- `unison/Unex/Services.u` — change ability `deploy : Text -> Link.Term -> Text` + handler
- `lib/unex/services.ex` — remove `deploy/3` and `compile_source/2`
- `lib/unex/api/services_controller.ex` — remove `deploy/1`
- `lib/unex/api/router.ex` — remove `POST /services/deploy`
- `test/example/service.u` — fix to wrap with `Unex.main`, deploy with `termLink`
- `test/unex/services_test.exs` — remove source-based deploy tests

**No new files required.**

---

## Task 1: Add `putBytes` HTTP helper

**Files:**
- Modify: `unison/Unex/Http/Helpers.u`

This is Unison-side only; verified by the integration test in Task 3.

- [ ] **Step 1: Append to Helpers.u**

Add to the end of `unison/Unex/Http/Helpers.u`:

```unison
-- PUT raw bytes to a URL (e.g. /bytecode/:hash).
-- Verify Body.fromBytes and HttpRequest.put exist in lib.unison_http by running:
--   find Body.fromBytes
--   find HttpRequest.put
-- in UCM before loading this file. If HttpRequest.put is absent, replace with
-- HttpRequest.post and change the route from PUT to POST.
Unex.Http.putBytes : Text -> Text -> Bytes -> {IO, Exception, Http, Threads} HttpResponse
Unex.Http.putBytes secret url bytes =
  Http.request
    (Unex.Http.authHeader secret
      (HttpRequest.addHeader "Content-Type" "application/octet-stream"
        (HttpRequest.put (URI.parse url) (Body.fromBytes bytes))))
```

- [ ] **Step 2: Commit**

```bash
git add unison/Unex/Http/Helpers.u
git commit -m "feat: add Unex.Http.putBytes for raw binary PUT requests"
```

---

## Task 2: Change `deploy` ability + handler

**Files:**
- Modify: `unison/Unex/Services.u`

- [ ] **Step 1: Update the ability block**

In `unison/Unex/Services.u`, change the `deploy` line inside `unique ability Unex.Services where` from:

```unison
  deploy : Text -> Text -> Text
```

to:

```unison
  deploy : Text -> Link.Term -> Text
```

- [ ] **Step 2: Replace the deploy handler case**

Remove the old `{ Unex.Services.deploy name source -> k }` case and replace it with:

```unison
  { Unex.Services.deploy name link -> k } ->
    use lib.base.reflection
    hash = Link.Term.toText link
    match Code.lookup link with
      None ->
        Exception.raise ("Unex.Services.deploy: term not found in runtime: " ++ hash)
      Some code ->
        bytes = Code.serialize_v3 code
        _ = Unex.Http.putBytes secret (baseUrl ++ "/bytecode/" ++ hash) bytes
        handle k hash with Unex.Services.handler baseUrl secret
```

- [ ] **Step 3: Add use declaration**

At the top of `Services.u`, add:

```unison
use lib.base.reflection
```

- [ ] **Step 4: Verify the file loads in UCM**

```
examples/main> load unison/Unex/Services.u
```

Expected: no typecheck errors.

- [ ] **Step 5: Commit**

```bash
git add unison/Unex/Services.u
git commit -m "feat: Services.deploy now uses Code.lookup + Code.serialize_v3 keyed by Unison hash"
```

---

## Task 3: Fix `service.u` example

**Files:**
- Modify: `test/example/service.u`

The key change: the service must be pre-wrapped with `Unex.main` before deploying, so the pushed bytecode is self-contained and runnable. The server runs it with `ucm run.compiled` and sets `UNEX_URL`/`UNEX_SECRET` env vars; `Unex.main` reads them and wires up all handlers.

- [ ] **Step 1: Rewrite service.u**

```unison
-- Example: Deploy a service using Code.lookup-based bytecode push.
--
-- myService is the application logic using Unex abilities.
-- mainService wraps it with Unex.main so connection details come from env vars.
-- The server receives fully compiled bytecode and runs it with ucm run.compiled.
--
-- Workflow from UCM:
--   1. load test/example/service.u
--   2. add
--   3. run mainDeploy

myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  Unex.Storage.writeCell "svc" "hits" "0"
  printLine "Service started"

-- Wrap with Unex.main so UNEX_URL and UNEX_SECRET are read from env at runtime.
-- This is the term whose bytecode gets pushed — it is self-contained.
mainService : '{IO, Exception} ()
mainService = Unex.main myService

deployScript : '{Unex.Services, IO, Exception} ()
deployScript = do
  -- deploy pushes bytecode for mainService and returns its Unison hash
  hash = Unex.Services.deploy "my-service" (termLink mainService)
  -- release points the name at the hash (or update to a new hash later)
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)

mainDeploy : '{IO, Exception} ()
mainDeploy = Unex.main deployScript
```

- [ ] **Step 2: Load in UCM and verify no errors**

```
examples/main> load test/example/service.u
```

Expected: all four terms typecheck successfully.

- [ ] **Step 3: Commit**

```bash
git add test/example/service.u
git commit -m "fix: update service.u — wrap service with Unex.main, deploy via termLink"
```

---

## Task 4: Remove server-side source compilation

**Files:**
- Modify: `lib/unex/services.ex`
- Modify: `lib/unex/api/services_controller.ex`
- Modify: `lib/unex/api/router.ex`

- [ ] **Step 1: Remove `deploy/3` from Services module**

In `lib/unex/services.ex`:
- Delete `def deploy(name, source, opts \\ [])` and its `@doc` (approximately lines 13–28)
- Delete `defp compile_source(source, entry_point)` and its `@doc` (approximately lines 74–89)

The module should now only have `release/2`, `call/2`, `list/0`, `undeploy/1`, and their helpers.

- [ ] **Step 2: Remove `deploy/1` from ServicesController**

In `lib/unex/api/services_controller.ex`, delete `def deploy(conn)` and its `@moduledoc`-level note. The controller should only have `release/2`, `call/2`, `list/1`, `undeploy/2`.

- [ ] **Step 3: Remove route**

In `lib/unex/api/router.ex`, delete:

```elixir
post "/services/deploy" do
  ServicesController.deploy(conn)
end
```

- [ ] **Step 4: Compile check**

```bash
mix compile
```

Expected: no undefined function warnings or errors.

- [ ] **Step 5: Update services tests**

In `test/unex/services_test.exs`, remove all tests that call `Services.deploy("name", source)`. Replace with tests that exercise `release` + `call` via pre-stored bytecode:

```elixir
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
```

- [ ] **Step 6: Run tests**

```bash
mix test test/unex/services_test.exs
```

Expected: all pass.

- [ ] **Step 7: Run full unit test suite**

```bash
mix test --exclude integration
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add lib/unex/services.ex lib/unex/api/services_controller.ex lib/unex/api/router.ex test/unex/services_test.exs
git commit -m "feat: remove source-based deploy; Services.release is the only registration path"
```

---

## Notes for Implementation

**Key assumption to verify (Task 2, Step 4):**
`Code.serialize_v3 (fromSome (Code.lookup (termLink mainService)))` must produce bytes that `ucm run.compiled` can execute. This is the spec's core claim ("Server only needs UCM for `run.compiled`"). If UCM rejects the bytes, investigate whether `compile` command output format differs from `Code.serialize_v3` output and file an issue.

**Link.Term.toText format:**
In UCM, run `display (Link.Term.toText (termLink myService))` to see the exact string format (e.g. `#abc123def`). The `BytecodeController` strips a leading `#` via `normalize_hash/1`, so the hash stored in HashCache will be `abc123def`. Confirm this matches what `Remote.do_execute` passes to `SyncServer.resolve`.

**`Body.fromBytes` / `HttpRequest.put` (Task 1):**
Verify with `find Body.fromBytes` and `find HttpRequest.put` in UCM. If absent, the fallback is to base64-encode bytes in a JSON POST body — the `BlobsController` pattern — and add a matching decode in a new bytecode endpoint.
