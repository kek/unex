# Uniops

Open-source ops platform for [Unison](https://www.unison-lang.org/). Provides durable storage, an HTTP API, and UCM process management — the foundation for running Unison programs without the proprietary Cloud runtime.

## Quick start

```bash
# Prerequisites: Elixir 1.17+, UCM (Unison Codebase Manager)
mix deps.get
mix uniops.start
```

The API starts on `http://localhost:4040` with zero configuration.

Verify it works:

```bash
curl -s localhost:4040/health
# {"status":"ok"}
```

## Storage API

Uniops exposes a JSON HTTP API for durable key-value storage backed by Mnesia.

```bash
# Create a database (a namespace for tables and cells)
curl -s -X POST localhost:4040/databases \
  -H 'Content-Type: application/json' \
  -d '{"name":"mydb"}'

# Create an ordered table (sorted key-value store)
curl -s -X POST localhost:4040/databases/mydb/tables/users

# Write a key-value pair
curl -s -X POST localhost:4040/databases/mydb/tables/users/write \
  -H 'Content-Type: application/json' \
  -d '{"key":"alice","value":"{\"age\":30,\"role\":\"admin\"}"}'

# Read it back
curl -s localhost:4040/databases/mydb/tables/users/read/alice

# Range scan (sorted, inclusive)
curl -s -X POST localhost:4040/databases/mydb/tables/users/scan \
  -H 'Content-Type: application/json' \
  -d '{"from":"a","to":"z"}'

# Cells (single durable values)
curl -s -X POST localhost:4040/databases/mydb/cells/counter/write \
  -H 'Content-Type: application/json' \
  -d '{"value":"42"}'

curl -s localhost:4040/databases/mydb/cells/counter/read

# Atomic transactions (all-or-nothing batch)
curl -s -X POST localhost:4040/databases/mydb/tx \
  -H 'Content-Type: application/json' \
  -d '{"operations":[
    {"op":"write_table","table":"users","key":"bob","value":"{}"},
    {"op":"write_cell","name":"last_updated","value":"2026-04-05"}
  ]}'
```

## Using from Unison

Uniops provides a Unison ability library so your programs use idiomatic `handle ... with` patterns instead of raw HTTP calls.

### Setup

1. In UCM, install the HTTP library:

```
myProject/main> lib.install @unison/http
```

2. Copy the `unison/` directory from this repo into your Unison project, or add the files individually.

3. Check the `use lib.unison_http_15_2_0` import in each file — the version suffix must match your installed `@unison/http` version. Check with `ls lib` in UCM.

### Example: Storage with abilities

```unison
myApp : '{UStorage, IO, Exception} ()
myApp = do
  UStorage.createDatabase "mydb"
  UStorage.createTable "mydb" "users"
  UStorage.write "mydb" "users" "alice" "{\"role\":\"admin\"}"

  match UStorage.read "mydb" "users" "alice" with
    Some val -> printLine ("Got: " ++ val)
    None -> printLine "Not found"

main : '{IO, Exception} ()
main = Uniops.main "http://localhost:4040" myApp
```

Run it (with uniops server running):

```
myProject/main> run main
Got: {"role":"admin"}
```

### Example: Config and Scratch

```unison
myApp : '{UConfig, UScratch, IO, Exception} ()
myApp = do
  UConfig.set "prod" "api_key" "sk-secret-123"

  match UConfig.get "prod" "api_key" with
    Some key -> printLine ("Key: " ++ key)
    None -> printLine "No key"

  UScratch.put "cache:session" "user-data"
  match UScratch.get "cache:session" with
    Some val -> printLine ("Cached: " ++ val)
    None -> printLine "Cache miss"
```

### Using individual handlers

You don't have to use all abilities. Compose only what you need:

```unison
main : '{IO, Exception} ()
main = do
  Threads.run do Http.run do
    handle !myApp with UStorage.handler "http://localhost:4040"
```

### Available abilities

| Ability | Operations |
|---------|-----------|
| `UStorage` | `createDatabase`, `createTable`, `write`, `read`, `delete`, `scan`, `writeCell`, `readCell`, `tx` |
| `UConfig` | `set`, `get`, `delete`, `list` |
| `UBlobs` | `write`, `read`, `delete`, `list` |
| `UScratch` | `put`, `get`, `delete` |
| `ULog` | `info`, `error`, `warn`, `recent` |
| `URemote` | `execute`, `submit` |
| `UServices` | `deploy`, `call`, `list`, `undeploy` |

### Mock handlers for testing

Write programs against abilities, test with mock handlers:

```unison
mockStorage : Request {UStorage} a -> a
mockStorage = cases
  { UStorage.read _ _ _ -> k } -> handle k (Some "mock-value") with mockStorage
  { UStorage.write _ _ _ _ -> k } -> handle k () with mockStorage
  { a } -> a

-- Test your app without a running server
test> myTest = check do
  result = handle !myApp with mockStorage
  -- assertions here
```

## Running a cluster

Uniops nodes use BEAM's built-in distribution to form clusters. Set a few environment variables and nodes auto-connect.

### Starting a two-node cluster

**Terminal 1 — node `a`:**

```bash
UNIOPS_NODE=a UNIOPS_COOKIE=secret UNIOPS_PORT=4040 UNIOPS_PEERS=b@$(hostname) mix uniops.start
```

**Terminal 2 — node `b`:**

```bash
UNIOPS_NODE=b UNIOPS_COOKIE=secret UNIOPS_PORT=4041 UNIOPS_PEERS=a@$(hostname) mix uniops.start
```

Nodes auto-connect — no manual `Node.connect` needed. Check from IEx:

```elixir
Node.list()
# => [:"a@myhostname"]
```

### Using a config file

For complex setups, use a config file instead of env vars:

```bash
# Copy the example
cp config.example.exs mynode.exs
# Edit it, then start
UNIOPS_CONFIG=mynode.exs mix uniops.start
```

Config files can also live at `~/.config/uniops/config.exs` or `/etc/uniops/config.exs`.

### Production deployment

Build a standalone release:

```bash
MIX_ENV=prod mix release
```

Run it:

```bash
# Single node
./bin/uniops start

# Cluster node
UNIOPS_NODE=a UNIOPS_COOKIE=secret UNIOPS_PEERS=b@10.0.1.2 ./bin/uniops start

# Attach console to running node
./bin/uniops remote
```

## Supporting Abilities

Uniops exposes Config, Blobs, Scratch, and Log — the remaining Unison Cloud abilities — via HTTP.

### Config (encrypted secrets)

```bash
# Store a secret (AES-256-GCM encrypted at rest)
curl -s -X POST localhost:4040/config/prod/api_key \
  -H 'Content-Type: application/json' \
  -d '{"value":"sk-secret-123"}'

# Read it back
curl -s localhost:4040/config/prod/api_key

# List keys for an environment
curl -s localhost:4040/config/prod
```

### Blobs (binary object storage)

```bash
# Write a blob (value is base64-encoded)
curl -s -X POST localhost:4040/blobs/mydb/images/photo.jpg \
  -H 'Content-Type: application/json' \
  -d "{\"data\":\"$(base64 < /path/to/photo.jpg)\"}"

# Read it back
curl -s localhost:4040/blobs/mydb/images/photo.jpg

# List by prefix
curl -s -X POST localhost:4040/blobs/mydb/list \
  -H 'Content-Type: application/json' \
  -d '{"prefix":"images/"}'
```

### Scratch (ephemeral cache)

```bash
# Store a temporary value
curl -s -X POST localhost:4040/scratch/session:abc \
  -H 'Content-Type: application/json' \
  -d '{"value":"user-data"}'

# Read it back (lost on restart)
curl -s localhost:4040/scratch/session:abc
```

### Log (structured logging)

```bash
# Append a log entry
curl -s -X POST localhost:4040/log \
  -H 'Content-Type: application/json' \
  -d '{"level":"info","message":"server started","metadata":{"port":4040}}'

# Read recent entries
curl -s localhost:4040/log/recent/20
```

## Configuration

Uniops resolves config in this order (first wins): environment variables → config file → built-in defaults.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UNIOPS_NODE` | *(none)* | Node name. Short name (`a`) for same subnet, FQDN (`a@10.0.1.5`) for cross-network |
| `UNIOPS_COOKIE` | *(none)* | Cluster auth cookie (required if `UNIOPS_NODE` is set) |
| `UNIOPS_PORT` | `4040` | HTTP API port |
| `UNIOPS_DATA` | `./data` | Base directory for Mnesia and blob storage |
| `UNIOPS_PEERS` | *(none)* | Comma-separated peer nodes to auto-connect |
| `UNIOPS_CONFIG_KEY` | *(generated)* | AES-256-GCM encryption key for Config secrets |
| `UNIOPS_CONFIG` | *(none)* | Path to config file |
| `UCM_PATH` | `ucm` | Path to UCM binary |

### Config file

See `config.example.exs` for a complete reference. Place at `~/.config/uniops/config.exs`, `/etc/uniops/config.exs`, or point to it with `UNIOPS_CONFIG`.

## Architecture

Uniops follows a two-layer architecture described in the [Unison mastery guide](unison-mastery-guide.md#part-xii):

- **Outer shell (Elixir/BEAM):** Manages UCM subprocesses, provides Mnesia-backed storage, hash cache, cross-node sync, and remote execution
- **Inner layer (Unison):** Your programs call the HTTP API using standard Unison abilities (`IO`, `Http`, `Threads`)

Roadmap:

1. ~~Elixir shell + UCM integration~~
2. ~~Storage (Mnesia) + HTTP API~~
3. ~~BEAM clustering + hash cache + dependency sync~~
4. ~~Remote execution (computation shipping)~~
5. ~~Services registry (typed RPC)~~
6. ~~Supporting abilities (Config, Blobs, Scratch, Log)~~

## Tests

```bash
mix test              # all 118 tests
mix test --trace      # verbose
```
