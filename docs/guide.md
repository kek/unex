# Uniops Guide

A hands-on guide to running Unison programs on the Uniops platform. By the end you'll have a Unison app that stores data, manages secrets, and caches state — all through idiomatic Unison abilities.

## Prerequisites

- **Elixir 1.17+** with Mix
- **UCM** (Unison Codebase Manager) 1.0+ on your PATH

## Part 1: Start the server

```bash
git clone <repo-url> uniops && cd uniops
mix deps.get
mix uniops.start
```

That's it. The API is live on `http://localhost:4040`. Verify:

```bash
curl -s localhost:4040/health
# {"status":"ok"}
```

You now have durable storage (Mnesia), encrypted config, blob storage, ephemeral cache, and structured logging — all behind a single HTTP API.

## Part 2: Set up your Unison project

Open a new terminal. Create a Unison project and install the HTTP library:

```
ucm

.> project.create myapp
myapp/main> lib.install @unison/http
```

Now copy the Uniops ability library into your project. From the repo root:

```bash
cp -r unison/ /path/to/your/unison/project/
```

The `unison/` directory contains:
- **Ability definitions** — `UStorage`, `UConfig`, `UBlobs`, `UScratch`, `ULog`, `URemote`, `UServices`
- **HTTP handlers** — translate each ability into calls to the Uniops API
- **`Uniops.main`** — composes all handlers so you can use every ability at once
- **Examples** — working programs you can run immediately

## Part 3: Your first Unison program on Uniops

Create a file `app.u` in your project:

```unison
myApp : '{UStorage, IO, Exception} ()
myApp = do
  -- Create a database and table
  UStorage.createDatabase "mydb"
  UStorage.createTable "mydb" "users"

  -- Write data
  UStorage.write "mydb" "users" "alice" "role=admin"
  UStorage.write "mydb" "users" "bob" "role=viewer"

  -- Read it back
  match UStorage.read "mydb" "users" "alice" with
    Some val -> printLine ("Alice: " ++ val)
    None -> printLine "Not found"

  -- Cells: single durable values
  UStorage.writeCell "mydb" "visitor_count" "42"
  match UStorage.readCell "mydb" "visitor_count" with
    Some n -> printLine ("Visitors: " ++ n)
    None -> printLine "No count"

  printLine "Done!"

main : '{IO, Exception} ()
main = Uniops.main "http://localhost:4040" myApp
```

Load and run it in UCM (with `mix uniops.start` running in another terminal):

```
myapp/main> load app.u
myapp/main> run main

  Alice: role=admin
  Visitors: 42
  Done!
```

### What just happened

Your program used the `UStorage` ability — an abstract interface for storage operations. It never called HTTP directly. The `Uniops.main` function wrapped your program in a handler that translates each `UStorage` operation into an HTTP call to the Uniops server. The handler pattern is:

```
Your program (uses UStorage)
    ↓
UStorage.handler (translates to HTTP)
    ↓
Uniops HTTP API (stores in Mnesia)
```

This separation means you can swap the handler for testing (see Part 7) or for a different backend — your program code doesn't change.

## Part 4: Encrypted secrets with Config

Uniops stores config values encrypted at rest with AES-256-GCM. Values are scoped by environment.

```unison
secretsApp : '{UConfig, IO, Exception} ()
secretsApp = do
  -- Store secrets (encrypted at rest)
  UConfig.set "prod" "api_key" "sk-live-abc123"
  UConfig.set "prod" "db_password" "supersecret"
  UConfig.set "staging" "api_key" "sk-test-xyz"

  -- Read them back
  match UConfig.get "prod" "api_key" with
    Some key -> printLine ("Prod key: " ++ key)
    None -> printLine "No key!"

  -- List all keys in an environment
  keys = UConfig.list "prod"
  printLine ("Prod keys: " ++ Text.join ", " keys)

main : '{IO, Exception} ()
main = Uniops.main "http://localhost:4040" secretsApp
```

```
myapp/main> run main

  Prod key: sk-live-abc123
  Prod keys: api_key, db_password
```

## Part 5: Ephemeral cache with Scratch

Scratch is a node-local, in-memory cache. Data is lost on server restart — use it for session state, caching, temporary data.

```unison
cacheApp : '{UScratch, IO, Exception} ()
cacheApp = do
  UScratch.put "session:user42" "name=Alice,role=admin"

  match UScratch.get "session:user42" with
    Some data -> printLine ("Session: " ++ data)
    None -> printLine "Cache miss"

  -- Delete when done
  UScratch.delete "session:user42"

main : '{IO, Exception} ()
main = Uniops.main "http://localhost:4040" cacheApp
```

## Part 6: Composing multiple abilities

The real power: use multiple abilities in one program. `Uniops.main` handles all seven.

```unison
fullApp : '{UStorage, UConfig, UScratch, ULog, IO, Exception} ()
fullApp = do
  ULog.info "Application starting"

  -- Set up storage
  UStorage.createDatabase "shop"
  UStorage.createTable "shop" "products"

  -- Store a secret
  UConfig.set "prod" "stripe_key" "sk-live-xxx"

  -- Write data
  UStorage.write "shop" "products" "widget" "price=9.99"

  -- Cache a recent query
  UScratch.put "last_product" "widget"

  -- Read everything back
  match UStorage.read "shop" "products" "widget" with
    Some val -> printLine ("Product: " ++ val)
    None -> printLine "Not found"

  match UConfig.get "prod" "stripe_key" with
    Some key -> printLine ("Stripe: " ++ Text.take 10 key ++ "...")
    None -> printLine "No key"

  ULog.info "Application finished"
  printLine "All done!"

main : '{IO, Exception} ()
main = Uniops.main "http://localhost:4040" fullApp
```

### Using individual handlers

You don't have to use all seven abilities. Compose only what you need:

```unison
-- Only Storage
main : '{IO, Exception} ()
main = do
  Threads.run do Http.run do
    handle !myStorageApp with UStorage.handler "http://localhost:4040"

-- Storage + Config
main : '{IO, Exception} ()
main = do
  Threads.run do Http.run do
    handle
      (handle !myApp with UStorage.handler "http://localhost:4040")
      with UConfig.handler "http://localhost:4040"
```

## Part 7: Testing with mock handlers

The ability pattern makes testing easy — swap the real HTTP handler for a mock:

```unison
mockStorage : Request {UStorage} a -> a
mockStorage = cases
  { UStorage.read _ _ _ -> k } -> handle k (Some "mock-value") with mockStorage
  { UStorage.write _ _ _ _ -> k } -> handle k () with mockStorage
  { UStorage.createDatabase _ -> k } -> handle k () with mockStorage
  { UStorage.createTable _ _ -> k } -> handle k () with mockStorage
  { a } -> a

-- Test your app without a running server
test> myTest = check do
  handle !myApp with mockStorage
  true
```

Your program doesn't know (or care) whether it's talking to a real server or a mock. This is the same pattern Unison Cloud uses — write once, run against any handler.

## Part 8: Running a cluster

### Two nodes on one machine

Terminal 1:
```bash
UNIOPS_NODE=a UNIOPS_COOKIE=secret UNIOPS_PORT=4040 UNIOPS_PEERS=b@$(hostname) mix uniops.start
```

Terminal 2:
```bash
UNIOPS_NODE=b UNIOPS_COOKIE=secret UNIOPS_PORT=4041 UNIOPS_PEERS=a@$(hostname) mix uniops.start
```

Nodes auto-connect. Data written to node `a`'s storage API is on node `a`'s Mnesia. Config (encrypted secrets) is also per-node. Scratch is always node-local.

### Across machines

Use full node names:

```bash
# Machine 1 (10.0.1.5)
UNIOPS_NODE=a@10.0.1.5 UNIOPS_COOKIE=secret UNIOPS_PEERS=b@10.0.1.6 mix uniops.start

# Machine 2 (10.0.1.6)
UNIOPS_NODE=b@10.0.1.6 UNIOPS_COOKIE=secret UNIOPS_PEERS=a@10.0.1.5 mix uniops.start
```

### Production deployment

```bash
MIX_ENV=prod mix release
UNIOPS_NODE=a UNIOPS_COOKIE=secret ./bin/uniops start
```

See `config.example.exs` for all options, or use environment variables (documented in README.md).

## Part 9: How it works

Uniops has two layers:

```
┌─────────────────────────────────────┐
│  Your Unison program                │
│  uses: UStorage, UConfig, UScratch  │
│            ↓ abilities              │
│  Ability handlers (Unison)          │
│  translates to HTTP calls           │
└───────────────┬─────────────────────┘
                │ HTTP
┌───────────────┴─────────────────────┐
│  Uniops server (Elixir/BEAM)       │
│                                     │
│  ┌──────────┐ ┌───────┐ ┌───────┐  │
│  │ Mnesia   │ │  ETS  │ │ Files │  │
│  │ Storage  │ │Scratch│ │ Blobs │  │
│  │ Config   │ │  Log  │ │       │  │
│  └──────────┘ └───────┘ └───────┘  │
│                                     │
│  BEAM distribution (clustering)     │
└─────────────────────────────────────┘
```

**Storage** (databases, tables, cells, transactions) — Mnesia, durable to disk.

**Config** — Mnesia with AES-256-GCM encryption. Secrets scoped by environment. The encryption key is set via `UNIOPS_CONFIG_KEY` (or auto-generated on first run).

**Blobs** — binary objects stored on the filesystem at `$UNIOPS_DATA/blobs/`.

**Scratch** — ETS (in-memory). Fast, node-local. Lost on restart.

**Log** — ETS ring buffer (keeps the last 1000 entries). Also forwards to Elixir's Logger.

**Remote** — compile Unison code to bytecode, ship it to another node, execute there.

**Services** — named, deployed Unison programs callable by name from any node.

## Available abilities reference

| Ability | Operations | Backend |
|---------|-----------|---------|
| `UStorage` | `createDatabase`, `listDatabases`, `createTable`, `write`, `read`, `delete`, `scan`, `writeCell`, `readCell`, `tx` | Mnesia |
| `UConfig` | `set`, `get`, `delete`, `list` | Mnesia + AES-256-GCM |
| `UBlobs` | `write`, `read`, `delete`, `list` | Filesystem |
| `UScratch` | `put`, `get`, `delete` | ETS |
| `ULog` | `info`, `error`, `warn`, `recent` | ETS ring buffer |
| `URemote` | `execute`, `submit` | BEAM distribution |
| `UServices` | `deploy`, `call`, `list`, `undeploy` | Registry + Remote |

## HTTP API reference

All abilities are also available directly via HTTP. See the [README](../README.md) for curl examples covering every endpoint.
