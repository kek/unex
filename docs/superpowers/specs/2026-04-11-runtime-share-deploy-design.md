# Runtime + Share Deploy Design

**Date:** 2026-04-11
**Status:** Approved
**Builds on:** POC (compile-on-client deploy working)

## Problem

The POC requires three manual steps in UCM: `add`, `compile mainService /tmp/svc`, then `run mainDeploy`. The compile step should happen on the server — the client just pushes code to Unison Share and tells the server to deploy.

## Design

### Architecture

The server runs a persistent UCM process (`Unex.Runtime`) with its own codebase. On deploy, it pulls the client's project from Unison Share and compiles the entry point to `.uc` bytecode. This mirrors Unison Cloud, where Share is the code distribution layer.

```
Client                    Unison Share              Server
  |                           |                       |
  |-- push @myorg/myapp ----->|                       |
  |                           |                       |
  |-- deploy "svc" #hash ----|----------------------->|
  |                           |                       |
  |                           |<-- pull @myorg/myapp --|
  |                           |-- code --------------->|
  |                           |                       |
  |                           |        compile #hash → .uc
  |                           |        store .uc in HashCache
  |                           |        register name → hash
  |<--- hash -----------------------------------------|
  |                           |                       |
  |-- call "svc" ------------|----------------------->|
  |                           |        ucm run.compiled .uc
  |<--- result ----------------------------------------|
```

### Deploy ability

```unison
unique ability Unex.Services where
  deploy : Text -> Link.Term -> Text    -- name, entry point → hash
  release : Text -> Text -> ()
  call : Text -> Text
  list : [Unex.ServiceInfo]
  undeploy : Text -> ()
```

The handler sends the entry point hash and Share project name to the server:

```unison
{ Unex.Services.deploy name link -> k } ->
    raw = Link.Term.toText link
    hash = if Text.take 1 raw == "#" then Text.drop 1 raw else raw
    project = match catch do IO.getEnv "UNEX_PROJECT" with
      Left _ -> bug "UNEX_PROJECT not set"
      Right p -> p
    resp = Unex.Http.postJson secret
      (baseUrl ++ "/services/" ++ name ++ "/deploy")
      (Unex.Http.toJson [("hash", hash), ("project", project)])
    deployHash = match Unex.Http.extractField (bodyText resp) "hash" with
      Some h -> h
      None -> bug "deploy failed"
    handle k deployHash with Unex.Services.handler baseUrl secret
```

### Server API

New endpoint:

```
POST /services/:name/deploy
  Body: {"hash": "<unison-hash>", "project": "@myorg/myapp"}
  Response: {"hash": "<sha256-of-uc>", "name": "<name>"}
```

This endpoint:
1. Tells `Unex.Runtime` to pull the project and compile the hash
2. Stores resulting `.uc` bytes in HashCache
3. Registers the service name → hash

### Unex.Runtime GenServer

Manages a persistent UCM process running in interactive mode with its own codebase.

**Startup:**
- Creates a codebase at `{data_dir}/runtime_codebase/`
- Starts UCM as a persistent port process: `ucm --codebase {codebase_path}`
- Installs base libraries if codebase is new: `lib.install @unison/base`, `lib.install @unison/http`, `lib.install @kek/unex`

**Deploy (compile request):**
1. Send to UCM: `pull @myorg/myapp.mainService .deployed.{hash}`
   (pulls the specific definition and its transitive deps into the server's codebase under a namespace)
2. Send to UCM: `compile .deployed.{hash} {output_path}`
3. Read the resulting `.uc` file
4. Return bytes to caller

**Concurrency:** Single UCM process handles one request at a time. Compile requests are serialized through the GenServer mailbox. Sufficient for POC; pool of workers is a future optimization.

**Lifecycle:** Started in the supervision tree. Restarts UCM if the port process dies.

### Execution

Unchanged from POC. `Remote.do_execute` writes `.uc` bytes to a temp file and runs `ucm run.compiled`. The `UNEX_URL` and `UNEX_SECRET` env vars are injected.

### User DX

**Setup (once):**
```bash
export UNEX_URL=http://localhost:4040
export UNEX_SECRET=<secret>
export UNEX_PROJECT=@myorg/myapp
```

**Deploy workflow:**
```
myapp/main> load service.u
myapp/main> add
myapp/main> push
myapp/main> load deploy.u
myapp/main> run mainDeploy

  Deployed: a1b2c3d4...
```

**Call:**
```
myapp/main> load call.u
myapp/main> run main

  {"stdout":"Service started\n",...}
```

### Example files

**service.u:**
```unison
myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  Unex.Storage.writeCell "svc" "hits" "0"
  printLine "Service started"

mainService : '{IO, Exception} ()
mainService = Unex.main myService
```

**deploy.u:**
```unison
deployScript : '{Unex.Services, IO, Exception} ()
deployScript = do
  hash = Unex.Services.deploy "my-service" (termLink mainService)
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)

mainDeploy : '{IO, Exception} ()
mainDeploy = Unex.main deployScript
```

**call.u:**
```unison
callScript : '{Unex.Services, IO, Exception} ()
callScript = do
  result = Unex.Services.call "my-service"
  printLine result

main : '{IO, Exception} ()
main = Unex.main callScript
```

## File changes

### New files

| File | Purpose |
|------|---------|
| `lib/unex/runtime.ex` | GenServer: persistent UCM process, pull + compile |
| `lib/unex/api/deploy_controller.ex` | Handler for `POST /services/:name/deploy` |

### Modified files

| File | Change |
|------|--------|
| `unison/Unex/Services.u` | deploy takes Link.Term again, sends hash + project to server |
| `lib/unex/api/router.ex` | Add deploy route |
| `lib/unex/application.ex` | Start Runtime in supervision tree |
| `lib/unex/remote.ex` | Remove Executor dependency (direct .uc execution) |
| `test/example/service.u` | Back to two-file workflow with add |
| `test/example/deploy.u` | Recreated — deploy via termLink |
| `docs/guide.md` | Updated deploy workflow |
| `CLAUDE.md` | Updated architecture |

### Removed (no longer needed)

| File | Reason |
|------|--------|
| `unison/executor.u` | Server compiles to .uc directly, no executor needed |
| `lib/unex/executor.ex` | Replaced by Runtime GenServer |

## What stays the same

- HashCache, SyncServer, Services.Registry
- `POST /services/:name/release`, `/call`, `GET /services`, `DELETE /services/:name`
- `POST /bytecode`, `GET /bytecode/:hash` (still useful for manual push)
- All non-Services abilities (Storage, Config, Blobs, Scratch, Log, Remote)
- `ucm run.compiled` execution path
