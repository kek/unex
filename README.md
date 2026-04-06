# unex - the unix hater's revenge

An open-source ops platform for [Unison](https://www.unison-lang.org/) programs. Durable storage, encrypted secrets, clustering, and content-addressed code execution orchestrated on the BEAM.

## Quick start

```bash
# Prerequisites: Elixir 1.17+, UCM (Unison Codebase Manager)
mix deps.get
mix unex.start
```

The API starts on `http://localhost:4040`. An API secret is auto-generated on first run (printed to stdout). Set `UNEX_API_SECRET` to persist it across restarts.

Verify it works:

```bash
curl -s localhost:4040/health
# {"status":"ok"}
```

## Storage API

All API endpoints (except `/health`) require a bearer token. Pass the secret printed at startup:

```bash
AUTH="Authorization: Bearer YOUR_SECRET"

# Create a database (a namespace for tables and cells)
curl -s -X POST localhost:4040/databases \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"name":"mydb"}'

# Create an ordered table (sorted key-value store)
curl -s -X POST localhost:4040/databases/mydb/tables/users \
  -H "$AUTH"

# Write a key-value pair
curl -s -X POST localhost:4040/databases/mydb/tables/users/write \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"key":"alice","value":"{\"age\":30,\"role\":\"admin\"}"}'

# Read it back
curl -s -H "$AUTH" localhost:4040/databases/mydb/tables/users/read/alice

# Range scan (sorted, inclusive)
curl -s -X POST localhost:4040/databases/mydb/tables/users/scan \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"from":"a","to":"z"}'

# Cells (single durable values)
curl -s -X POST localhost:4040/databases/mydb/cells/counter/write \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"value":"42"}'

curl -s -H "$AUTH" localhost:4040/databases/mydb/cells/counter/read

# Atomic transactions (all-or-nothing batch)
curl -s -X POST localhost:4040/databases/mydb/tx \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"operations":[
    {"op":"write_table","table":"users","key":"bob","value":"{}"},
    {"op":"write_cell","name":"last_updated","value":"2026-04-05"}
  ]}'
```

## Using from Unison

Unex provides a Unison ability library so your programs use idiomatic `handle ... with` patterns instead of raw HTTP calls.

### Setup

1. In UCM, install the HTTP library:

```
myProject/main> lib.install @unison/http
```

2. Copy the `unison/` directory from this repo into your Unison project, or add the files individually.

That's it. The library names resolve automatically — no version-specific imports needed.

### Example: Storage with abilities

```unison
myApp : '{Unex.Storage, IO, Exception} ()
myApp = do
  Unex.Storage.createDatabase "mydb"
  Unex.Storage.createTable "mydb" "users"
  Unex.Storage.write "mydb" "users" "alice" "role=admin"

  match Unex.Storage.read "mydb" "users" "alice" with
    Some val -> printLine ("Got: " ++ val)
    None -> printLine "Not found"

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" "my-secret" myApp
```

Run it (with `mix unex.start` running in another terminal):

```
myapp/main> load app.u
myapp/main> run main

  Got: role=admin
```

### Example: Config and Scratch

```unison
myApp : '{Unex.Config, Unex.Scratch, IO, Exception} ()
myApp = do
  Unex.Config.set "prod" "api_key" "sk-secret-123"

  match Unex.Config.get "prod" "api_key" with
    Some key -> printLine ("Key: " ++ key)
    None -> printLine "No key"

  Unex.Scratch.put "cache:session" "user-data"
  match Unex.Scratch.get "cache:session" with
    Some val -> printLine ("Cached: " ++ val)
    None -> printLine "Cache miss"

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" "my-secret" myApp
```

### Available abilities

| Ability | Operations | Backend |
|---------|-----------|---------|
| `Unex.Storage` | `createDatabase`, `createTable`, `write`, `read`, `delete`, `scan`, `writeCell`, `readCell`, `tx` | Mnesia |
| `Unex.Config` | `set`, `get`, `delete`, `list` | Mnesia + AES-256-GCM |
| `Unex.Blobs` | `write`, `read`, `delete`, `list` | Filesystem |
| `Unex.Scratch` | `put`, `get`, `delete` | ETS (node-local) |
| `Unex.Log` | `info`, `error`, `warn`, `recent` | ETS ring buffer |
| `Unex.Remote` | `execute`, `submit` | BEAM distribution |
| `Unex.Services` | `deploy`, `call`, `list`, `undeploy` | Registry + Remote |

You can use all abilities at once via `Unex.main`, or compose individual handlers. See the **[full tutorial](docs/guide.md)** for composing handlers, mock testing, clustering, and architecture details.

## Running a cluster

Unex nodes use BEAM's built-in distribution to form clusters. Set a few environment variables and nodes auto-connect.

### Starting a two-node cluster

**Terminal 1 — node `a`:**

```bash
UNEX_NODE=a UNEX_COOKIE=secret UNEX_PORT=4040 UNEX_PEERS=b@$(hostname) mix unex.start
```

**Terminal 2 — node `b`:**

```bash
UNEX_NODE=b UNEX_COOKIE=secret UNEX_PORT=4041 UNEX_PEERS=a@$(hostname) mix unex.start
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
UNEX_CONFIG=mynode.exs mix unex.start
```

Config files can also live at `~/.config/unex/config.exs` or `/etc/unex/config.exs`.

### Production deployment

Build a standalone release:

```bash
MIX_ENV=prod mix release
```

Run it:

```bash
# Single node
./bin/unex start

# Cluster node
UNEX_NODE=a UNEX_COOKIE=secret UNEX_PEERS=b@10.0.1.2 ./bin/unex start

# Attach console to running node
./bin/unex remote
```

## Supporting Abilities

Unex exposes Config, Blobs, Scratch, and Log — the remaining Unison Cloud abilities — via HTTP.

### Config (encrypted secrets)

```bash
# Store a secret (AES-256-GCM encrypted at rest)
curl -s -X POST localhost:4040/config/prod/api_key \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"value":"sk-secret-123"}'

# Read it back
curl -s -H "$AUTH" localhost:4040/config/prod/api_key

# List keys for an environment
curl -s -H "$AUTH" localhost:4040/config/prod
```

### Blobs (binary object storage)

```bash
# Write a blob (value is base64-encoded)
curl -s -X POST localhost:4040/blobs/mydb/images/photo.jpg \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"data\":\"$(base64 < /path/to/photo.jpg)\"}"

# Read it back
curl -s -H "$AUTH" localhost:4040/blobs/mydb/images/photo.jpg

# List by prefix
curl -s -X POST localhost:4040/blobs/mydb/list \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"prefix":"images/"}'
```

### Scratch (ephemeral cache)

```bash
# Store a temporary value
curl -s -X POST localhost:4040/scratch/session:abc \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"value":"user-data"}'

# Read it back (lost on restart)
curl -s -H "$AUTH" localhost:4040/scratch/session:abc
```

### Log (structured logging)

```bash
# Append a log entry
curl -s -X POST localhost:4040/log \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"level":"info","message":"server started","metadata":{"port":4040}}'

# Read recent entries
curl -s -H "$AUTH" localhost:4040/log/recent/20
```

## Configuration

Unex resolves config in this order (first wins): environment variables → config file → built-in defaults.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UNEX_NODE` | *(none)* | Node name. Short name (`a`) for same subnet, FQDN (`a@10.0.1.5`) for cross-network |
| `UNEX_COOKIE` | *(none)* | Cluster auth cookie (required if `UNEX_NODE` is set) |
| `UNEX_PORT` | `4040` | HTTP API port |
| `UNEX_DATA` | `./data` | Base directory for Mnesia and blob storage |
| `UNEX_PEERS` | *(none)* | Comma-separated peer nodes to auto-connect |
| `UNEX_API_SECRET` | *(generated)* | Bearer token for API authentication |
| `UNEX_CONFIG_KEY` | *(generated)* | AES-256-GCM encryption key for Config secrets |
| `UNEX_CONFIG` | *(none)* | Path to config file |
| `UCM_PATH` | `ucm` | Path to UCM binary |

### Config file

See `config.example.exs` for a complete reference. Place at `~/.config/unex/config.exs`, `/etc/unex/config.exs`, or point to it with `UNEX_CONFIG`.

## Architecture

Unex follows a two-layer architecture:

```
┌──────────────────────────────────────┐
│  Your Unison program                 │
│  (uses Unex.Storage, Unex.Config, etc.)      │
│              ↓ abilities             │
│  Ability handlers → HTTP calls       │
└──────────────┬───────────────────────┘
               │ HTTP
┌──────────────┴───────────────────────┐
│  Unex server (Elixir/BEAM)        │
│  Mnesia · ETS · Filesystem · Crypto  │
│  BEAM distribution (clustering)      │
└──────────────────────────────────────┘
```

- **Outer shell (Elixir/BEAM):** UCM subprocess management, Mnesia storage, hash cache, cross-node sync, remote execution
- **Inner layer (Unison):** Your programs use abstract abilities; handlers translate to HTTP
- **Unison ability library:** `Unex.Storage`, `Unex.Config`, `Unex.Blobs`, `Unex.Scratch`, `Unex.Log`, `Unex.Remote`, `Unex.Services`

For a deep dive, see the [tutorial](docs/guide.md) and the [Introduction to Unison](docs/introduction-to-unison.md).

## Tests

```bash
mix test              # all tests
mix test --trace      # verbose
```
