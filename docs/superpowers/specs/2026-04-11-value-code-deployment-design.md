# Value + Code Deployment Design

**Date:** 2026-04-11
**Status:** Approved
**Supersedes:** 2026-04-09-deployment-and-secrets-design.md (deployment sections only; env-var and secrets sections remain valid)

## Problem

The current deploy system uses `Code.serialize_v3` to serialize bytecode on the client, stores it on the server, and runs it with `ucm run.compiled`. This is broken: `Code.serialize_v3` produces Unison's **Code serialization format** (definition metadata), while `ucm run.compiled` expects the **StoredCache format** (compiled closures). These are incompatible binary formats — UCM fails with "insufficient bytes in getBytes".

There is no Unison builtin that produces StoredCache format. The `.uc` format is host-only, created by the `ucm compile` command (Haskell-side `interpCompile`).

Additionally, the current deploy requires a two-file + `add` workflow because `termLink` needs the term to be in the codebase.

## Goals

1. Deployed services actually run (fix the format mismatch)
2. Deploy UX matches Unison Cloud — pass the function value directly, single file, no `add` step
3. Use the same Value + Code transfer protocol Unison Cloud uses for distributed execution
4. Keep the system simple enough for a working proof of concept

## Design

### 1. Deploy ability takes a function value (not Link.Term)

```unison
-- Before (broken)
unique ability Unex.Services where
  deploy : Text -> Link.Term -> Text

-- After (Unison Cloud style)
unique ability Unex.Services where
  deploy : Text -> '{IO, Exception} () -> Text
  release : Text -> Text -> ()
  call : Text -> Text
  list : [Unex.ServiceInfo]
  undeploy : Text -> ()
```

User code:

```unison
myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  Unex.Storage.writeCell "svc" "hits" "0"
  printLine "Service started"

mainService : '{IO, Exception} ()
mainService = Unex.main myService

main : '{IO, Exception} ()
main = Unex.main do
  hash = Unex.Services.deploy "my-service" mainService
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)
```

Single file. No `termLink`. No `add`. Load and run.

### 2. Value + Code serialization (the Unison Cloud protocol)

The deploy handler serializes the function using the same protocol Unison Cloud uses for distributed execution:

1. `Value.value fn` — wrap the runtime closure into a `Value`
2. `Value.serialize val` — serialize to bytes
3. `Value.dependencies val` — get all `[Link.Term]` the closure references
4. For each dep: `Code.lookup dep` → `Code.serialize code` — serialize each dependency
5. Package into a binary **bundle**

#### Bundle format

```
[4 bytes: deps section length, big-endian u32]
[deps section bytes: Value.serialize'd [(Link.Term, Bytes)]]
[remaining bytes: Value.serialize'd function closure]
```

Two sections separated by a length prefix:
- **Deps section** — contains `[(Link.Term, Bytes)]` where each Bytes is a serialized Code entry. Uses only builtin types (Link.Term, Bytes, List, tuples) so it can be deserialized without any user code cached.
- **Function section** — the serialized function closure. Requires deps to be cached first.

### 3. Transport and storage

The bundle bytes are hex-encoded in JSON and POSTed to the server:

```
POST /bytecode   {"data": "<hex-encoded bundle>"}  → 201 {"hash": "<sha256>"}
```

The server computes SHA256 of the raw bundle bytes as the storage key. No client-side hash needed. The hash is returned in the response.

The existing `GET /bytecode/:hash` endpoint continues to work for pulling stored bundles.

HashCache stores raw bundle bytes (not `.uc` format). The bundle is only meaningful when executed through the executor.

### 4. Server-side execution via executor

A **static executor program** (`executor.uc`) replaces the direct `ucm run.compiled` path.

#### Execution flow

```
Service call → resolve name → hash → retrieve bundle from HashCache
  ↓
Write bundle to temp file: /tmp/unex_bundle_{hash}.bin
  ↓
Run executor.uc with env vars:
  UNEX_BUNDLE=/tmp/unex_bundle_{hash}.bin
  UNEX_URL=http://localhost:4040
  UNEX_SECRET=<secret>
  ↓
Executor reads bundle, caches code, loads value, executes function
  ↓
Clean up temp file
```

#### Executor program logic

```
Read UNEX_BUNDLE env var → read file bytes
  ↓
Parse bundle: extract deps section (first 4 bytes = length) + function section
  ↓
Value.deserialize deps bytes → Value.load → [(Link.Term, Bytes)]
  ↓
For each pair: Code.deserialize bytes → collect [(Link.Term, Code)]
  ↓
Code.cache_ all entries → error if any deps still missing
  ↓
Value.deserialize function bytes → Value.load → '{IO, Exception} ()
  ↓
!fn (execute)
```

The executor uses **only Unison builtins** — no library imports. This means it compiles in an empty codebase via the existing `Compiler.compile` module.

#### Executor lifecycle

- Source: `unison/executor.u`
- Compiled `.uc` cached at `{data_dir}/executor.uc`
- Managed by `Unex.Executor` GenServer, started in supervision tree
- Compiled on server startup using `Compiler.compile`
- Recompiled if source mtime changes or `.uc` missing

### 5. API changes

| Endpoint | Change |
|----------|--------|
| `POST /bytecode` (new) | Accept bundle bytes, compute SHA256, store, return hash |
| `POST /bytecode/:hash` | Removed — old format incompatible with executor |
| `GET /bytecode/:hash` | Unchanged (returns raw bundle bytes) |
| `POST /services/:name/release` | Unchanged |
| `POST /services/:name/call` | Unchanged (executor handles execution internally) |
| `GET /services` | Unchanged |
| `DELETE /services/:name` | Unchanged |

### 6. Example: full deploy + call workflow

```unison
myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  Unex.Storage.writeCell "svc" "hits" "0"
  printLine "Service started"

mainService : '{IO, Exception} ()
mainService = Unex.main myService

app : '{Unex.Services, IO, Exception} ()
app = do
  -- Deploy: serialize + push + get hash
  hash = Unex.Services.deploy "my-service" mainService
  -- Release: point name at hash
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)

  -- Call: execute on server
  result = Unex.Services.call "my-service"
  printLine ("Result: " ++ result)

main : '{IO, Exception} ()
main = Unex.main app
```

```
myapp/main> load service.u
myapp/main> run main

  Deployed: a1b2c3d4...
  Result: {"stdout":"Service started\n","stderr":"","exit_code":0}
```

## File changes

### New files

| File | Purpose |
|------|---------|
| `unison/executor.u` | Executor source — builtins only, reads bundle, caches code, loads + runs value |
| `lib/unex/executor.ex` | GenServer: compiles executor on startup, provides `executor_path/0` |

### Modified files

| File | Change |
|------|--------|
| `unison/Unex/Services.u` | `deploy : Text -> '{IO, Exception} () -> Text`; Value+Code handler |
| `lib/unex/api/bytecode_controller.ex` | Add `POST /bytecode` (hashless, server-computed SHA256) |
| `lib/unex/api/router.ex` | Add hashless bytecode route |
| `lib/unex/remote.ex` | `do_execute` writes bundle to file, runs executor |
| `lib/unex/application.ex` | Start `Unex.Executor` in supervision tree |
| `test/example/service.u` | Merged: service + deploy in one file, value-based |
| `test/example/call.u` | Updated for new response format |
| `docs/guide.md` | Part 9 rewritten; new Part 11 for @kek/unex release workflow |
| `docs/api.md` | Bytecode section updated |
| `CLAUDE.md` | Architecture description updated |

### Removed files

| File | Reason |
|------|--------|
| `test/example/deploy.u` | Merged into `test/example/service.u` |

## What changes vs. previous design

| Previous (broken) | New |
|---|---|
| `deploy : Text -> Link.Term -> Text` | `deploy : Text -> '{IO, Exception} () -> Text` |
| `Code.serialize_v3` (Code format) | `Value.serialize` + `Code.serialize` (Value+Code format) |
| Raw bytes written as `.uc` + `run.compiled` | Bundle written to file + executor.uc loads it |
| Hash = Unison hash from `Link.Term.toText` | Hash = SHA256 of bundle bytes |
| Two files + `add` + `termLink` | Single file, pass function value directly |
| `POST /bytecode/:hash` only | `POST /bytecode` (hashless) added |

## What stays the same

- All existing abilities (Storage, Config, Blobs, Scratch, Log, Remote)
- All HTTP API endpoints for those abilities
- Elixir infrastructure (Mnesia, ETS, Bandit, Auth plug)
- `Unex.main` reading env vars (from the secrets design)
- Services Registry, name → hash pointer model
- `release`, `call`, `list`, `undeploy` operations
- Cluster distribution model (SyncServer, PeerConnector)

## Publishing @kek/unex

When the Unison-side files (`unison/Unex/*.u`, `unison/Main.u`) change, a new version of `@kek/unex` must be published to Unison Share so users can `lib.install` the updated library.

### Release workflow

1. **Open the library project in UCM:**
   ```
   ucm
   .> project.open kek/unex
   kek/unex/main>
   ```

2. **Load changed files and update definitions:**
   ```
   kek/unex/main> load unison/Unex/Services.u
   kek/unex/main> update
   kek/unex/main> load unison/Main.u
   kek/unex/main> update
   ```
   Repeat for each changed `.u` file. `update` replaces existing definitions in the codebase.

3. **Verify everything typechecks:**
   ```
   kek/unex/main> test
   ```

4. **Create a release:**
   ```
   kek/unex/main> release.draft 0.2.0
   kek/unex/releases/0.2.0> push
   ```

5. **Users update:**
   ```
   myapp/main> lib.install @kek/unex
   ```
   UCM resolves to the latest version automatically.

### When to release

- Any change to ability signatures (like `deploy` type change) is a **breaking change** — bump minor version
- New abilities or handler bug fixes — bump patch version
- Document the change in the release notes when prompted by `release.draft`
