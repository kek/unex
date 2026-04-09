# Deployment and Secrets Design

**Date:** 2026-04-09  
**Status:** Approved

## Problem

The current `Unex.main` takes `baseUrl` and `secret` as explicit parameters:

```unison
main = Unex.main "http://localhost:4040" "my-secret" myApp
```

This means every program that uses Unex has infrastructure details baked into source code. You cannot share the program on Unison Share, and deployed services on the server would need to hardcode the URL they're calling back to. This is the opposite of how Unison Cloud works, where app code is pure ability usage with no connection details.

## Goals

1. App code (programs using `Unex.Storage`, `Unex.Config`, etc.) is shareable on Unison Share with no secrets or URLs.
2. Deploy scripts are also pure Unison — no mix CLI required for the primary path.
3. The developer experience matches Unison Cloud as closely as possible.
4. Shipping bytecode from a laptop uses the same mechanism as distributing bytecode across cluster nodes.

## Design

### 1. `Unex.main` reads from environment variables

`Unex.main` takes only the program — no URL, no secret:

```unison
Unex.main : '{Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch,
              Unex.Log, Unex.Remote, Unex.Services, IO, Exception} a
          -> '{IO, Exception} a
Unex.main program = do
  baseUrl = Optional.getOrElse "http://localhost:4040" (IO.getEnv "UNEX_URL")
  secret  = Optional.getOrElse "" (IO.getEnv "UNEX_SECRET")
  Threads.run do Http.run do
    handle ... !program ... with handlers baseUrl secret
```

User app code becomes shareable:

```unison
myApp : '{Unex.Storage, Unex.Config, IO, Exception} ()
myApp = do
  Unex.Storage.write "mydb" "users" "alice" "admin"
  match Unex.Config.get "prod" "api_key" with
    Some k -> printLine k
    None   -> printLine "no key"

main : '{IO, Exception} ()
main = Unex.main myApp
```

Running locally, the user sets env vars in their shell:

```bash
export UNEX_URL=http://localhost:4040
export UNEX_SECRET=my-secret
# then in UCM:
myProject/main> run main
```

An escape hatch for tests or explicit configuration:

```unison
Unex.main.withConfig : Text -> Text
  -> '{Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch,
       Unex.Log, Unex.Remote, Unex.Services, IO, Exception} a
  -> '{IO, Exception} a
```

### 2. Content-addressed bytecode store keyed by Unison hash

The existing `HashCache` is re-keyed from SHA256-of-bytes to **Unison hash**. Every Unison definition already has a content-addressed hash (SHA3-512, base32hex, prefixed with `#`) that is its universal identity — in codebases, on Share, everywhere.

```
HashCache:  Unison hash  →  bytecode
            #abc123def   →  <.uc bytes>
```

This is the single source of truth for bytecode. It is populated by three mechanisms, all doing the same thing:

| Source | Transport | Operation |
|--------|-----------|-----------|
| Laptop push | HTTP `PUT /bytecode/:hash` | Write bytes into HashCache |
| Cluster node sync | Erlang RPC | Write bytes into HashCache |
| Cluster node pull | HTTP `GET /bytecode/:hash` | Read bytes from HashCache |

Laptop push and node-to-node sync are the same operation over different transports. The key space is shared and universal.

### 3. Deployment = naming

A "deployment" is a pointer from a human-readable name to a Unison hash. "Releasing" a new version is updating the pointer. Rollback is pointing it back. The bytecode is immutable and already in the cache.

```
ServiceRegistry:  name          →  Unison hash
                  "my-service"  →  #abc123def
```

API:

```
PUT    /bytecode/:hash             push bytecode (idempotent)
GET    /bytecode/:hash             pull bytecode

POST   /services/:name/release     {hash: "#abc123def"} — point name at hash
DELETE /services/:name             remove name
GET    /services/:name             current hash + history
GET    /services                   all names + current hashes

POST   /services/:name/call        resolve name → execute hash
```

### 4. Deploying from Unison code

Unison provides two pure builtins for reflection:

- `termLink myFunction : Link.Term` — compile-time reference to a term
- `Link.Term.toText : Link.Term -> Text` — extract the hash as `"#abc123def..."` (pure, no IO)
- `Code.lookup : Link.Term -> {IO} Optional Code` — retrieve bytecode from the running runtime

This means the `Unex.Services.deploy` handler can get both the hash and the bytecode from the running Unison program itself — no UCM subprocess needed for compilation:

```unison
-- The handler (inside Unex.Services.handler) does:
hash     = Link.Term.toText (termLink program)   -- pure
bytecode = Code.lookup (termLink program)         -- IO
-- then POSTs bytecode to PUT /bytecode/:hash
-- then POSTs to POST /services/:name/release
```

The user-facing deploy API is pure Unison, mirroring Unison Cloud:

```unison
-- Unison Cloud
main = Cloud.main do
  Cloud.deploy env myService

-- Unex
main = Unex.main do
  Unex.Services.deploy "my-service" myService
```

Release, rollback, and inspection are also ability operations:

```unison
main = Unex.main do
  Unex.Services.deploy  "my-service" myServiceV2   -- push + point name at new hash
  Unex.Services.release "my-service" oldHash        -- point name at any existing hash
  services = Unex.Services.list                     -- [{name, hash}]
```

The `Unex.Services` ability signature changes from taking source `Text` to taking a program value:

```unison
-- Before
unique ability Unex.Services where
  deploy : Text -> Text -> Text   -- name, source → hash

-- After
unique ability Unex.Services where
  deploy  : Text -> '{IO, Exception} a -> Text   -- name, program → hash
  release : Text -> Text -> ()                   -- name, hash → ()
  list    : [Unex.ServiceInfo]
  undeploy : Text -> ()
```

### 5. Server-side execution of deployed services

When the server calls a deployed service via `POST /services/:name/call`, it:

1. Resolves the name to a hash in the registry
2. Retrieves bytecode from HashCache (or syncs from a peer node)
3. Sets `UNEX_URL=http://localhost:4040` and `UNEX_SECRET=<internal-secret>` as env vars
4. Runs `ucm run.compiled service.uc`

The bytecode was compiled with `Unex.main` already baked in. `Unex.main` reads the env vars set by the server, wires up the handlers, and the service makes HTTP calls back to the local server. No secrets are ever in source code.

### 6. CLI (secondary path, for CI/CD)

A `mix unex` CLI is provided as a convenience for pipelines that don't use UCM:

```bash
mix unex.push   myProject.myService        # compile + push bytecode, prints hash
mix unex.release my-service "#abc123def"   # point name at hash
mix unex.deploy  my-service myProject.myService  # push + release in one step
mix unex.services                          # list all names + hashes
mix unex.rollback my-service               # revert to previous hash
```

This is not the primary path — UCM + Unison abilities are.

## What changes

| Today | After |
|-------|-------|
| `Unex.main "url" "secret" myApp` | `Unex.main myApp` |
| `Services.deploy name sourceText` | `Services.deploy name program` (actual value) |
| HashCache keyed by SHA256 of bytes | HashCache keyed by Unison hash |
| Deploy = compile source on server | Deploy = push pre-compiled bytecode |
| No versioning or history | Names are pointers; history is tracked |
| Server needs UCM for compilation | Server only needs UCM for `run.compiled` |

## What stays the same

- All existing abilities (`Unex.Storage`, `Unex.Config`, `Unex.Blobs`, `Unex.Scratch`, `Unex.Log`)
- All existing HTTP API endpoints for those abilities
- All Elixir-side infrastructure (Mnesia, ETS, Bandit, Auth plug)
- `SyncServer` / cluster distribution model — just re-keyed
