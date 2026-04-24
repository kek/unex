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

### 4. Server-side extraction

The server's `Runtime` GenServer receives the deploy request and spawns a UCM subprocess. Instead of producing a standalone `.uc` file, it **extracts** the entry point as:

- A serialized `Value` for the root thunk (`Value.serialize_v4`)
- Every transitively reachable `Code` definition (`Code.serialize_v3`), keyed by its `Link.Term` hash

The extractor is a small `.u` file generated per deploy, with the entry point name interpolated into the source. Running it under `ucm run.file` walks the closure graph and writes each piece to disk.

```
pull @myorg/myapp                -- fetch from Unison Share
load /tmp/extract/_extractor.u   -- generated: references mainService by name
run Unex.Extract.main            -- walk deps, write root.value + <hash>.code files
exit
```

The Runtime maintains a persistent codebase at `data/runtime_codebase/` with `@unison/base`, `@unison/http`, and `@kek/unex` pre-installed. Each `pull` incrementally syncs the developer's project.

Back on the Elixir side, Unex reads the output directory and:

- Stores the root `Value` bytes in `HashCache` under its SHA256 (this is the service's "hash").
- Stores each `Code` blob in `HashCache` keyed by its `Link.Term` text so the dispatcher can fetch it by hash later.
- Registers the service name in `Services.Registry` pointing to the root-value hash.

`##builtin` terms (e.g. `##IO.getEnv.impl.v1`, `##Nat.+`) are skipped — Unison can't serialize foreign operations, and the dispatcher has every base-library primitive baked in anyway.

### 5. Execution

A single long-lived dispatcher process evaluates every service call. There is no per-call UCM subprocess.

**Boot:** On app start, `Unex.Dispatcher` listens on `127.0.0.1:0` and spawns `ucm run.compiled $UNEX_DISPATCHER`. The Unison program reads `UNEX_DISPATCHER_PORT` from its environment, connects back via `Socket.client`, and enters a request loop. Elixir accepts the one incoming connection.

**Per request (`POST /services/:name/call`):**

1. `Services.Registry` resolves the name to a root-value hash.
2. `SyncServer` fetches the serialized `Value` bytes from the cluster (local `HashCache`, or a peer via RPC).
3. `Unex.Dispatcher.eval` sends `<<len::8, value_bytes>>` over the protocol socket.
4. The Unison dispatcher `Value.deserialize`s, `Value.load`s as a `'{IO, Exception} ()` thunk, and **iteratively satisfies missing `Code` deps** by issuing `GET /code/:termhash` back to the same Elixir server. Fetched codes are `Code.cache_`'d; `Value.load` is retried until all deps resolve.
5. The thunk runs for its side effects. Anything the user program writes to `stdout` is captured by Elixir from the subprocess's pipe (the protocol is on a separate socket, so `printLine` is free to use stdout).
6. On completion, the dispatcher sends an OK response frame. Elixir wraps the accumulated stdout in `%Runner.Result{stdout: ..., stderr: "", exit_code: 0}` and returns it to the caller.

Because the dispatcher is persistent, typical service calls complete in single-digit milliseconds instead of the several seconds a cold `ucm run.compiled` takes.

**Concurrency.** The dispatcher is currently single-inflight — calls queue on the GenServer. Adding a pool is a future concern.

**Remote nodes.** `Services.call` with `:node` opts RPCs `eval_local/2` on the target node, which has its own local dispatcher. The Code store is cluster-replicated via `SyncServer`, so any node can serve any service.

## Cluster distribution

Unex nodes form a cluster using BEAM distribution (Erlang's built-in node-to-node communication).

```
Node A (port 4040)  <-- BEAM distribution -->  Node B (port 4041)
  HashCache (ETS)                                 HashCache (ETS)
  SyncServer                                      SyncServer
  Services.Registry                               Services.Registry
  Mnesia (local)                                  Mnesia (local)
```

### Code distribution

`HashCache` on each node stores content-addressed blobs in ETS:

- **Root `Value` bytes**, keyed by SHA256 (each deployed service has one).
- **`Code` bytes**, keyed by `Link.Term` hash (one per definition referenced across all services).

When a node is missing a key, `SyncServer` asks connected peers via RPC. Anything retrieved from a peer is cached locally.

This means deploying to one node makes a service available to all nodes. The first node whose dispatcher needs a particular `Code` fetches it from the deploying node; subsequent calls use the local cache.

### Service registry

`Services.Registry` maps service names to `{hash, node, deployed_at}` entries. Each entry records which node the service was deployed on. When a node receives a call for a service it doesn't have registered locally, it asks peers via RPC.

### Execution routing

`Services.call` defaults to running on the local node's dispatcher. Callers can pass `node: <peer>` to route a call to a specific peer — Unex RPCs `Services.eval_local/2` there, which goes through that node's dispatcher.

### What is shared vs. local

| Component | Scope | Notes |
|-----------|-------|-------|
| HashCache (Values + Code) | Cluster-wide via SyncServer | Cached locally after first fetch |
| Services.Registry | Cluster-wide via peer resolution | Name -> root-value hash -> node |
| Unex.Dispatcher | Per-node | Long-lived `ucm run.compiled` with protocol over localhost socket |
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
  +-- Unex.Cluster.HashCache      ETS content-addressed cache (Value + Code)
  +-- Unex.Cluster.SyncServer     Cross-node key resolution
  +-- Unex.Services.Registry      Service name -> root-value-hash mapping
  +-- Unex.Abilities.Scratch      ETS ephemeral key-value
  +-- Unex.Abilities.Log          ETS ring buffer
  +-- Unex.Runtime                Persistent UCM codebase for extraction
  +-- Unex.Dispatcher             (if dispatcher.uc present) Long-lived evaluator
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
- **Bytecode** — push/pull arbitrary `.uc` bundles (legacy; not used by the dispatcher deploy flow)
- **Code** — `GET /code/:termhash` serves a serialized `Code` blob; the dispatcher fetches its missing deps through this endpoint
- **Services** — deploy, release, call, list, undeploy, `/services/:name/web` (HTML wrapper over `call`)

### UCM interaction

The server interacts with UCM in two places:

1. **Extraction** (`Runtime`). Spawns a short-lived UCM with `--codebase` pointing to the persistent runtime codebase. Sends `pull` + `load` + `run Unex.Extract.main` via stdin. Reads the serialized `Value` + `Code` blobs from the output directory. One extraction at a time (serialized through the GenServer). Runs only at deploy time.

2. **The dispatcher** (`Unex.Dispatcher`). Spawns one UCM at app boot with `run.compiled $UNEX_DISPATCHER` and keeps it alive. Every service call is a message over the dispatcher's TCP socket — no new UCM subprocess per call. The compiled `dispatcher.uc` is produced once per image/release by `mix unex.compile_dispatcher`; at runtime it reads `UNEX_URL` + `UNEX_SECRET` from the environment to call back into this server's `/code/:termhash` endpoint for any `Code` it's missing.

Because the dispatcher bundle's hash is tied to the exact UCM version that built it, image builds must pin UCM. In Docker, the same `UCM_VERSION` build arg is shared between the build and runtime stages; the bundle lives at `/app/dispatcher.uc` (outside the data volume) so a mounted `/app/data` doesn't shadow it.

## Dashboard (opt-in)

An opt-in Phoenix LiveView subsystem under `lib/unex_dashboard/`, started
only when `:start_dashboard` is true. It runs in the same BEAM node as
core (shared ETS/process space for zero-cost observation) but maintains
a one-way dependency: core must not reference `Unex.Dashboard.*` except
for `Unex.Dashboard.Events`, which is the contract module for PubSub
broadcasts. The boundary is enforced by a source-scan test
(`test/unex_dashboard/boundary_test.exs`).

`Phoenix.PubSub` is always started by `Unex.Application`; when the
dashboard is off, broadcasts simply have no subscribers. Core publishes
to three topics: `"hashcache"` (put), `"services"` (register / unregister
/ call_started / call_finished), and `"cluster"` (node up).

The dashboard listens on a separate port (`:4041` default) and is
protected by HTTP Basic Auth. It embeds `Phoenix.LiveDashboard` at
`/dashboard` for VM/Bandit/Mnesia inspection alongside custom LiveViews
at `/services`, `/cluster`, `/hash/:id`, and `/swarm`.
