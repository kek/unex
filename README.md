# Uniops

Open-source ops platform for [Unison](https://www.unison-lang.org/). Provides durable storage, an HTTP API, and UCM process management — the foundation for running Unison programs without the proprietary Cloud runtime.

## Quick start

```bash
# Prerequisites: Elixir 1.17+, UCM (Unison Codebase Manager)
mix deps.get
mix run --no-halt
```

The storage API starts on `http://localhost:4040`. Change the port with `UNIOPS_API_PORT=8080`.

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

This is the point of the whole project. Your Unison programs talk to uniops over HTTP using the `@unison/http` library.

### Setup

In UCM, install the HTTP library:

```
myProject/main> lib.install @unison/http
```

### Example: write and read from storage

```unison
use lib.unison_http_15_2_0
use lib.base.IO

-- Helper: POST JSON to a URL
postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
postJson url body =
  req =
    HttpRequest.addHeader "Content-Type" "application/json"
      (HttpRequest.post (URI.parse url) (Body.fromText body))
  Http.request req

-- Helper: GET a URL and return body as Text
getJson : Text -> {IO, Exception, Http, Threads} Text
getJson url = bodyText (Http.get (URI.parse url))

main : '{IO, Exception} ()
main = do
  base = "http://localhost:4040"

  Threads.run do Http.run do
    -- Create a database
    _ = postJson (base ++ "/databases") "{\"name\":\"mydb\"}"

    -- Create a table
    _ = postJson (base ++ "/databases/mydb/tables/items") ""

    -- Write some data
    _ = postJson
          (base ++ "/databases/mydb/tables/items/write")
          "{\"key\":\"hello\",\"value\":\"world\"}"

    -- Read it back
    body = getJson (base ++ "/databases/mydb/tables/items/read/hello")
    printLine ("Got: " ++ body)
```

Run it (with uniops server running in another terminal):

```
myProject/main> run main
Got: {"key":"hello","value":"world"}
```

### Example: using cells as counters

```unison
use lib.unison_http_15_2_0
use lib.base.IO

main : '{IO, Exception} ()
main = do
  base = "http://localhost:4040"

  Threads.run do Http.run do
    -- Write a cell
    req =
      HttpRequest.addHeader "Content-Type" "application/json"
        (HttpRequest.post
          (URI.parse (base ++ "/databases/mydb/cells/visits/write"))
          (Body.fromText "{\"value\":\"1\"}"))
    _ = Http.request req

    -- Read the cell
    body = bodyText (Http.get (URI.parse (base ++ "/databases/mydb/cells/visits/read")))
    printLine ("Visits: " ++ body)
```

### Notes on the Unison HTTP API

- Wrap HTTP calls in `Threads.run do Http.run do ...` to handle the required abilities
- `Http.get` returns an `HttpResponse` directly; `Http.request` takes an `HttpRequest` for POST/PUT/DELETE
- `bodyText` extracts the response body as `Text`
- `HttpRequest.post` takes a `URI` and a `Body` (`Body.fromText` for strings, `Body.empty` for no body)
- `HttpRequest.addHeader` sets request headers (needed for `Content-Type: application/json`)

The `use lib.unison_http_15_2_0` line imports the HTTP library namespace. The exact version suffix depends on which version of `@unison/http` you have installed — check with `ls lib` in UCM.

## Running a cluster

Uniops nodes use BEAM's built-in distribution to form clusters. Each node runs its own storage, hash cache, and remote execution service.

### Starting a two-node cluster

**Terminal 1 — start node `a`:**

```bash
UNIOPS_API_PORT=4040 \
UNIOPS_MNESIA_DIR=/tmp/uniops_a \
iex --sname a --cookie uniops_secret -S mix
```

**Terminal 2 — start node `b` and connect to `a`:**

```bash
UNIOPS_API_PORT=4041 \
UNIOPS_MNESIA_DIR=/tmp/uniops_b \
iex --sname b --cookie uniops_secret -S mix
```

Then connect from node `b`:

```elixir
Node.connect(:"a@#{node() |> Atom.to_string() |> String.split("@") |> List.last()}")
# true
iex(b)> Node.list()
# => [:"a@Q0H6M77WWM"]  (your hostname will differ)
```

Key points:
- `--sname` gives each node a short name (use `--name` for fully qualified names across machines)
- `--cookie` must match on all nodes in the cluster
- Each node needs its own `UNIOPS_API_PORT` and `UNIOPS_MNESIA_DIR`
- UCM must be on PATH on every machine in the cluster

### Validating the cluster

From an IEx session on any node:

```elixir
# Check connected peers
Node.list()
# => [:"a@Q0H6M77WWM"]

# Cache some bytecode on this node
hash = Uniops.Cluster.HashCache.put("test data")

# Verify a peer can resolve it (pulls from us via SyncServer)
[peer | _] = Node.list()
:rpc.call(peer, Uniops.Cluster.SyncServer, :resolve, [Uniops.Cluster.SyncServer, [hash]])
# => {:ok, %{"abc123..." => "test data"}}
```

### Remote execution

Compile a Unison program and execute it on a remote node:

```elixir
# On node a: compile and cache bytecode
source = "main : '{IO, Exception} ()\nmain = do printLine \"hello from remote!\""
{:ok, ws} = Uniops.Workspace.create("/tmp/uniops_compile")
{:ok, path} = Uniops.Workspace.write_source(ws, "prog.u", source)
{:ok, uc_path} = Uniops.Compiler.compile(ws, path, "main", "prog")
hash = Uniops.Cluster.HashCache.put(File.read!(uc_path))

# Execute on node b — bytecode syncs automatically
[peer | _] = Node.list()
{:ok, result} = Uniops.Remote.execute(hash, node: peer)
result.stdout
# => "hello from remote!\n"

# Or let the system pick a node
{:ok, result} = Uniops.Remote.submit(hash)
```

The flow: compile locally → cache bytecode by hash → call `execute` with target node → target resolves the hash from peers → writes temp `.uc` file → runs via UCM → returns stdout/stderr.

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `UNIOPS_API_PORT` | `4040` | HTTP API port |
| `UNIOPS_MNESIA_DIR` | system tmp dir | Where Mnesia stores data on disk |
| `UCM_PATH` | `ucm` | Path to UCM binary |

BEAM distribution flags (passed to `elixir`/`iex`):

| Flag | Example | Description |
|------|---------|-------------|
| `--sname` | `--sname a` | Short node name (same subnet) |
| `--name` | `--name a@10.0.1.5` | Full node name (cross-network) |
| `--cookie` | `--cookie secret` | Cluster auth token (must match) |

## Architecture

Uniops follows a two-layer architecture described in the [Unison mastery guide](unison-mastery-guide.md#part-xii):

- **Outer shell (Elixir/BEAM):** Manages UCM subprocesses, provides Mnesia-backed storage, hash cache, cross-node sync, and remote execution
- **Inner layer (Unison):** Your programs call the HTTP API using standard Unison abilities (`IO`, `Http`, `Threads`)

Roadmap:

1. ~~Elixir shell + UCM integration~~
2. ~~Storage (Mnesia) + HTTP API~~
3. ~~BEAM clustering + hash cache + dependency sync~~
4. ~~Remote execution (computation shipping)~~
5. Services registry (typed RPC)
6. Supporting abilities (Config, Blobs, Scratch, Log)

## Tests

```bash
mix test              # all 70 tests
mix test --trace      # verbose
```
