# Unex Guide

A hands-on guide to running Unison programs on the Unex platform. By the end you'll have a Unison app that stores data, manages secrets, and caches state — all through idiomatic Unison abilities.

## Prerequisites

- **Elixir 1.17+** with Mix
- **UCM** (Unison Codebase Manager) 1.0+ on your PATH

## Part 1: Start the server

```bash
git clone <repo-url> unex && cd unex
mix deps.get
mix unex.start
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

Now copy the Unex ability library into your project. From the repo root:

```bash
cp -r unison/ /path/to/your/unison/project/
```

The `unison/` directory contains:
- **Ability definitions** — `Unex.Storage`, `Unex.Config`, `Unex.Blobs`, `Unex.Scratch`, `Unex.Log`, `Unex.Remote`, `Unex.Services`
- **HTTP handlers** — translate each ability into calls to the Unex API
- **`Unex.main`** — composes all handlers so you can use every ability at once
- **Examples** — working programs you can run immediately

## Part 3: Your first Unison program on Unex

Create a file `app.u` in your project:

```unison
myApp : '{Unex.Storage, IO, Exception} ()
myApp = do
  -- Create a database and table
  Unex.Storage.createDatabase "mydb"
  Unex.Storage.createTable "mydb" "users"

  -- Write data
  Unex.Storage.write "mydb" "users" "alice" "role=admin"
  Unex.Storage.write "mydb" "users" "bob" "role=viewer"

  -- Read it back
  match Unex.Storage.read "mydb" "users" "alice" with
    Some val -> printLine ("Alice: " ++ val)
    None -> printLine "Not found"

  -- Cells: single durable values
  Unex.Storage.writeCell "mydb" "visitor_count" "42"
  match Unex.Storage.readCell "mydb" "visitor_count" with
    Some n -> printLine ("Visitors: " ++ n)
    None -> printLine "No count"

  printLine "Done!"

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" myApp
```

Load and run it in UCM (with `mix unex.start` running in another terminal):

```
myapp/main> load app.u
myapp/main> run main

  Alice: role=admin
  Visitors: 42
  Done!
```

### What just happened

Your program used the `Unex.Storage` ability — an abstract interface for storage operations. It never called HTTP directly. The `Unex.main` function wrapped your program in a handler that translates each `Unex.Storage` operation into an HTTP call to the Unex server. The handler pattern is:

```
Your program (uses Unex.Storage)
    ↓
Unex.Storage.handler (translates to HTTP)
    ↓
Unex HTTP API (stores in Mnesia)
```

This separation means you can swap the handler for testing (see Part 7) or for a different backend — your program code doesn't change.

## Part 4: Encrypted secrets with Config

Unex stores config values encrypted at rest with AES-256-GCM. Values are scoped by environment.

```unison
secretsApp : '{Unex.Config, IO, Exception} ()
secretsApp = do
  -- Store secrets (encrypted at rest)
  Unex.Config.set "prod" "api_key" "sk-live-abc123"
  Unex.Config.set "prod" "db_password" "supersecret"
  Unex.Config.set "staging" "api_key" "sk-test-xyz"

  -- Read them back
  match Unex.Config.get "prod" "api_key" with
    Some key -> printLine ("Prod key: " ++ key)
    None -> printLine "No key!"

  -- List all keys in an environment
  keys = Unex.Config.list "prod"
  printLine ("Prod keys: " ++ Text.join ", " keys)

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" secretsApp
```

```
myapp/main> run main

  Prod key: sk-live-abc123
  Prod keys: api_key, db_password
```

## Part 5: Ephemeral cache with Scratch

Scratch is a node-local, in-memory cache. Data is lost on server restart — use it for session state, caching, temporary data.

```unison
cacheApp : '{Unex.Scratch, IO, Exception} ()
cacheApp = do
  Unex.Scratch.put "session:user42" "name=Alice,role=admin"

  match Unex.Scratch.get "session:user42" with
    Some data -> printLine ("Session: " ++ data)
    None -> printLine "Cache miss"

  -- Delete when done
  Unex.Scratch.delete "session:user42"

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" cacheApp
```

## Part 6: Composing multiple abilities

The real power: use multiple abilities in one program. `Unex.main` handles all seven.

```unison
fullApp : '{Unex.Storage, Unex.Config, Unex.Scratch, Unex.Log, IO, Exception} ()
fullApp = do
  Unex.Log.info "Application starting"

  -- Set up storage
  Unex.Storage.createDatabase "shop"
  Unex.Storage.createTable "shop" "products"

  -- Store a secret
  Unex.Config.set "prod" "stripe_key" "sk-live-xxx"

  -- Write data
  Unex.Storage.write "shop" "products" "widget" "price=9.99"

  -- Cache a recent query
  Unex.Scratch.put "last_product" "widget"

  -- Read everything back
  match Unex.Storage.read "shop" "products" "widget" with
    Some val -> printLine ("Product: " ++ val)
    None -> printLine "Not found"

  match Unex.Config.get "prod" "stripe_key" with
    Some key -> printLine ("Stripe: " ++ Text.take 10 key ++ "...")
    None -> printLine "No key"

  Unex.Log.info "Application finished"
  printLine "All done!"

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" fullApp
```

### Using individual handlers

You don't have to use all seven abilities. Compose only what you need:

```unison
-- Only Storage
main : '{IO, Exception} ()
main = do
  Threads.run do Http.run do
    handle !myStorageApp with Unex.Storage.handler "http://localhost:4040"

-- Storage + Config
main : '{IO, Exception} ()
main = do
  Threads.run do Http.run do
    handle
      (handle !myApp with Unex.Storage.handler "http://localhost:4040")
      with Unex.Config.handler "http://localhost:4040"
```

## Part 7: Testing with mock handlers

The ability pattern makes testing easy — swap the real HTTP handler for a mock:

```unison
mockStorage : Request {Unex.Storage} a -> a
mockStorage = cases
  { Unex.Storage.read _ _ _ -> k } -> handle k (Some "mock-value") with mockStorage
  { Unex.Storage.write _ _ _ _ -> k } -> handle k () with mockStorage
  { Unex.Storage.createDatabase _ -> k } -> handle k () with mockStorage
  { Unex.Storage.createTable _ _ -> k } -> handle k () with mockStorage
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
UNEX_NODE=a UNEX_COOKIE=secret UNEX_PORT=4040 UNEX_PEERS=b@$(hostname) mix unex.start
```

Terminal 2:
```bash
UNEX_NODE=b UNEX_COOKIE=secret UNEX_PORT=4041 UNEX_PEERS=a@$(hostname) mix unex.start
```

Nodes auto-connect. Data written to node `a`'s storage API is on node `a`'s Mnesia. Config (encrypted secrets) is also per-node. Scratch is always node-local.

### Across machines

Use full node names:

```bash
# Machine 1 (10.0.1.5)
UNEX_NODE=a@10.0.1.5 UNEX_COOKIE=secret UNEX_PEERS=b@10.0.1.6 mix unex.start

# Machine 2 (10.0.1.6)
UNEX_NODE=b@10.0.1.6 UNEX_COOKIE=secret UNEX_PEERS=a@10.0.1.5 mix unex.start
```

### Production deployment

```bash
MIX_ENV=prod mix release
UNEX_NODE=a UNEX_COOKIE=secret ./bin/unex start
```

See `config.example.exs` for all options, or use environment variables (documented in README.md).

## Part 9: How it works

Unex has two layers:

```
┌─────────────────────────────────────┐
│  Your Unison program                │
│  uses: Unex.Storage, Unex.Config, Unex.Scratch  │
│            ↓ abilities              │
│  Ability handlers (Unison)          │
│  translates to HTTP calls           │
└───────────────┬─────────────────────┘
                │ HTTP
┌───────────────┴─────────────────────┐
│  Unex server (Elixir/BEAM)       │
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

**Config** — Mnesia with AES-256-GCM encryption. Secrets scoped by environment. The encryption key is set via `UNEX_CONFIG_KEY` (or auto-generated on first run).

**Blobs** — binary objects stored on the filesystem at `$UNEX_DATA/blobs/`.

**Scratch** — ETS (in-memory). Fast, node-local. Lost on restart.

**Log** — ETS ring buffer (keeps the last 1000 entries). Also forwards to Elixir's Logger.

**Remote** — compile Unison code to bytecode, ship it to another node, execute there.

**Services** — named, deployed Unison programs callable by name from any node.

## Available abilities reference

| Ability | Operations | Backend |
|---------|-----------|---------|
| `Unex.Storage` | `createDatabase`, `listDatabases`, `createTable`, `write`, `read`, `delete`, `scan`, `writeCell`, `readCell`, `tx` | Mnesia |
| `Unex.Config` | `set`, `get`, `delete`, `list` | Mnesia + AES-256-GCM |
| `Unex.Blobs` | `write`, `read`, `delete`, `list` | Filesystem |
| `Unex.Scratch` | `put`, `get`, `delete` | ETS |
| `Unex.Log` | `info`, `error`, `warn`, `recent` | ETS ring buffer |
| `Unex.Remote` | `execute`, `submit` | BEAM distribution |
| `Unex.Services` | `deploy`, `call`, `list`, `undeploy` | Registry + Remote |

## HTTP API reference

All abilities are also available directly via HTTP. See the [README](../README.md) for curl examples covering every endpoint.
