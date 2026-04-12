# Unex Architecture

Unex is an ops platform for Unison programs. It provides durable storage, encrypted secrets, clustering, and content-addressed code execution on the BEAM. Developers write Unison programs using idiomatic abilities; the platform handles compilation, distribution, and execution.

## Two-layer design

```
Unison programs (abilities)
        |
        | HTTP
        v
Elixir/BEAM server (storage, execution, clustering)
```

**Unison layer.** Programs use abilities like `Unex.Storage`, `Unex.Config`, and `Unex.Services`. These are abstract interfaces — the program never calls HTTP or touches infrastructure directly. `Unex.main` composes handlers that translate each ability into HTTP calls against the Elixir API. Connection details come from environment variables (`UNEX_URL`, `UNEX_SECRET`), so programs contain no credentials and are safe to publish on Unison Share.

**Elixir layer.** A BEAM application that provides the HTTP API, Mnesia-backed storage, ETS caches, filesystem blob storage, AES-256-GCM encrypted config, and BEAM distribution for clustering. UCM (the Unison Codebase Manager) runs as a subprocess for compilation and execution.

## How code gets from developer to running system

### 1. Write

The developer writes a Unison program using Unex abilities:

```unison
myService : '{Unex.Storage, IO, Exception} ()
myService = do
  Unex.Storage.createDatabase "svc"
  printLine "Service started"

mainService : '{IO, Exception} ()
mainService = Unex.main myService
```

`mainService` wraps `myService` with `Unex.main`, which reads `UNEX_URL` and `UNEX_SECRET` from the environment at runtime and wires up all ability handlers. This is the entry point that the server will compile and execute.

### 2. Push to Unison Share

```
myapp/main> load service.u
myapp/main> add
myapp/main> push
```

Definitions are added to the local codebase and pushed to Unison Share. Share is the code distribution layer — the same role it plays in Unison Cloud. The server pulls code from Share; it never receives source text or serialized bytecode directly from the client.

### 3. Deploy

```unison
deployScript = do
  hash = Unex.Services.deploy "my-service" "mainService"
  Unex.Services.release "my-service" hash
  printLine ("Deployed: " ++ hash)
```

The `deploy` ability sends two pieces of information to the server:
- The function name (`"mainService"`)
- The Unison Share project (from the `UNEX_PROJECT` environment variable)

### 4. Server-side compilation

The server's `Runtime` GenServer receives the deploy request and spawns a UCM subprocess:

```
pull @myorg/myapp          -- fetch code from Unison Share
compile mainService /tmp/output   -- compile to .uc bytecode
exit
```

The Runtime maintains a persistent codebase at `data/runtime_codebase/` with `@unison/base`, `@unison/http`, and `@kek/unex` pre-installed. Each `pull` incrementally syncs the developer's project. The `compile` command produces a standalone `.uc` file containing the compiled program and all its transitive dependencies.

The `.uc` bytes are stored in `HashCache` (ETS, keyed by SHA256) and the service name is registered in `Services.Registry` pointing to that hash.

### 5. Execution

When a service is called (`POST /services/:name/call`):

1. `Services.Registry` resolves the name to a bytecode hash
2. `SyncServer` retrieves the `.uc` bytes from `HashCache` (or from a peer node via RPC)
3. The bytes are written to a temporary file
4. UCM executes it: `ucm run.compiled /tmp/service.uc`
5. The server injects `UNEX_URL` and `UNEX_SECRET` as environment variables
6. The program starts, `Unex.main` reads those env vars, and the ability handlers make HTTP calls back to the local server's API
7. stdout/stderr and exit code are captured and returned to the caller

Each service call is an isolated UCM subprocess. The program runs, produces output, and exits.

## Cluster distribution

Unex nodes form a cluster using BEAM distribution (Erlang's built-in node-to-node communication).

```
Node A (port 4040)  <-- BEAM distribution -->  Node B (port 4041)
  HashCache (ETS)                                 HashCache (ETS)
  SyncServer                                      SyncServer
  Services.Registry                               Services.Registry
  Mnesia (local)                                  Mnesia (local)
```

### Bytecode distribution

`HashCache` on each node stores `.uc` bytecode in ETS, keyed by SHA256. When a node needs bytecode it doesn't have locally, `SyncServer` asks connected peers via RPC. Any bytecode retrieved from a peer is cached locally.

This means deploying to one node makes the bytecode available to all nodes. The first node to call the service fetches the bytecode from the deploying node; subsequent calls use the local cache.

### Service registry

`Services.Registry` maps service names to `{hash, node, deployed_at}` entries. Each entry records which node the service was deployed on. When a node receives a call for a service it doesn't have registered locally, it asks peers via RPC.

### Execution routing

`Remote.execute` runs bytecode on a specific node. `Remote.submit` picks a random peer and executes there, falling back to local execution if no peers are connected. This provides basic load distribution across the cluster.

### What is shared vs. local

| Component | Scope | Notes |
|-----------|-------|-------|
| HashCache (bytecode) | Cluster-wide via SyncServer | Cached locally after first fetch |
| Services.Registry | Cluster-wide via peer resolution | Name -> hash -> node |
| Mnesia (Storage) | Per-node | Each node has its own databases and tables |
| Config (secrets) | Per-node | AES-256-GCM encrypted, stored in Mnesia |
| Scratch (cache) | Per-node | ETS, lost on restart |
| Log | Per-node | ETS ring buffer |
| Blobs | Per-node | Filesystem at `data/blobs/` |
| Runtime (compilation) | Per-node | Each node has its own UCM codebase |

## Server components

```
Unex.Application (supervisor)
  |
  +-- Unex.Cluster.HashCache      ETS bytecode cache
  +-- Unex.Cluster.SyncServer     Cross-node bytecode resolution
  +-- Unex.Services.Registry      Service name -> hash mapping
  +-- Unex.Abilities.Scratch      ETS ephemeral key-value
  +-- Unex.Abilities.Log          ETS ring buffer
  +-- Unex.Runtime                Persistent UCM codebase for compilation
  +-- Unex.Cluster.PeerConnector  (if peers configured) Auto-connect with backoff
  +-- Bandit HTTP server          (if API enabled) Serves the HTTP API on :4040
```

### HTTP API

All endpoints except `/health` require bearer token authentication. The API is the interface between Unison programs and the server:

- **Storage** — databases, tables, cells, transactions (Mnesia)
- **Config** — encrypted secrets by environment (Mnesia + AES-256-GCM)
- **Blobs** — binary objects (filesystem)
- **Scratch** — ephemeral cache (ETS)
- **Log** — structured log entries (ETS ring buffer)
- **Bytecode** — push/pull compiled `.uc` bytes
- **Services** — deploy, release, call, list, undeploy

### UCM interaction

The server interacts with UCM in two ways:

1. **Compilation** (`Runtime`). Spawns UCM with `--codebase` pointing to the persistent runtime codebase. Sends `pull` + `compile` commands via stdin. Reads the resulting `.uc` file. One compilation at a time (serialized through the GenServer).

2. **Execution** (`Runner`). Spawns UCM with `run.compiled <path>`. The process runs the program, captures stdout/stderr, and exits. Each service call is a separate subprocess. Environment variables (`UNEX_URL`, `UNEX_SECRET`) are injected so the program can call back to the server's API.
