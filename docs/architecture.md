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

**Per request (`POST /services/:name/call` or `GET /<name>`):**

1. `Services.Registry.resolve(name)` returns the current root-value hash. On a node that doesn't own the entry, the registry GenServer falls back to `ask_peers(Node.list(), name)` and `GenServer.call({Registry, peer}, {:lookup, name})` on each connected peer until one answers.
2. `SyncServer.resolve([hash])` returns the serialized `Value` bytes. Local `HashCache` first; on miss, `ask_peers` does `GenServer.call({SyncServer, peer}, {:fetch_local, hash})` on each connected peer. Anything fetched is immediately `HashCache.put`'d so the next call is local.
3. `Unex.Dispatcher.eval` sends `<<len::8, value_bytes>>` over the protocol socket to the local dispatcher.
4. The Unison dispatcher `Value.deserialize`s, `Value.load`s as a `'{IO, Exception} ()` thunk, and **iteratively satisfies missing `Code` deps** by issuing `GET /code/:termhash` back to its own node's API (the URL was wired in at dispatcher boot). The handler is `CodeController.get/2`, which itself goes through `SyncServer.resolve/1` — so a `Code` blob the local node has never seen is also pulled from peers on demand. Fetched codes are `Code.cache_`'d; `Value.load` is retried until all deps resolve.
5. The thunk runs for its side effects. Anything the user program writes to `stdout` is captured by Elixir from the subprocess's pipe (the protocol is on a separate socket, so `printLine` is free to use stdout).
6. On completion, the dispatcher sends an OK response frame. Elixir wraps the accumulated stdout in `%Runner.Result{stdout: ..., stderr: "", exit_code: 0}` and returns it to the caller.

Because the dispatcher is persistent, typical service calls complete in single-digit milliseconds instead of the several seconds a cold `ucm run.compiled` takes.

**Concurrency.** The dispatcher is currently single-inflight — calls queue on the GenServer. Adding a pool is a future concern.

**Remote nodes.** `Services.call` with `:node` opts RPCs `eval_local/2` on the target node, which has its own local dispatcher. By default the call stays local: every node can serve any service because both the registry entry and the code blobs are reachable on demand through the layers above.

## Cluster distribution

Unex nodes form a cluster using BEAM distribution (Erlang's built-in node-to-node communication).

```
Node A (port 4040)  <-- BEAM distribution -->  Node B (port 4050)
  HashCache (ETS + disk)                          HashCache (ETS + disk)
  SyncServer                                      SyncServer
  Services.Registry                               Services.Registry
  Mnesia (local)                                  Mnesia (local)
```

Nothing is eagerly replicated. Every node has the same components, and the cluster is held together by two demand-driven lookup paths — one for *which version* (registry) and one for *the bytes of that version* (HashCache via SyncServer). Both fall back to peer RPC on local miss.

### Two layers of indirection

| Question                       | Lookup mechanism                                                                                                                                                                                                                                                                                                                       |
|--------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `service_name → root_hash`     | `Services.Registry`. Per-node ETS map of `name → %Entry{hash, deploy_node, deployed_at, project, entry_point}`. `Registry.resolve/1` reads local ETS first; on miss, walks `Node.list()` doing `GenServer.call({Registry, peer}, {:lookup, name})` until one answers.                                                                |
| `hash → bytes`                 | `HashCache` + `SyncServer`. Per-node ETS keyed by SHA-256 (root `Value` bytes) or `Link.Term` text (per-term `Code` bytes), mirrored to disk under `<UNEX_DATA>/hashcache/`. `SyncServer.resolve/1` checks local; on miss, walks `Node.list()` doing `GenServer.call({SyncServer, peer}, {:fetch_local, hash})`. Anything pulled is `HashCache.put`'d so subsequent reads stay local. |

Both fallbacks query connected peers sequentially. If no peer has the entry/blob, the request fails with `:not_found`.

### Walkthrough: `GET /counter` on node B (deployed on A)

1. **Registry resolve.** B's `Services.Registry.resolve("counter")` misses ETS, asks peers, A returns the `%Entry{}` with the current `hash`.
2. **Root value fetch.** `Services.eval_local(hash)` calls `SyncServer.resolve([hash])`. B's `HashCache` misses, asks peers, A serves the bytes. B caches.
3. **Hand off to dispatcher.** B's local `Unex.Dispatcher` (its own long-lived `ucm run.compiled` subprocess) deserializes the `Value` and starts running the thunk.
4. **Lazy code fetch.** Whenever the runtime hits a `Link.Term` reference whose bytecode it hasn't loaded, the Unison dispatcher issues `GET http://localhost:<B's api port>/code/<termhash>` (the callback URL was hard-wired at dispatcher boot from `:api_port`). B's `CodeController.get/2` calls `SyncServer.resolve([termhash])` — same local-then-peer fallback. A serves the bytes; B caches them. The dispatcher `Code.cache_`'s the result and continues.
5. **Result.** Stdout from the subprocess is captured by Elixir and returned as the response body (HTML for `/<name>`, JSON for `/services/:name/call`).

The first call on B touches the network for the registry entry, the root `Value`, and however many `Code` blobs the evaluation actually walks. The second call is fully local — every blob it needed is now in B's `HashCache`. This is what "redeploy is kilobytes" actually means in practice.

### Versioning

Hash *is* the version — content addressing collapses naming and identity. Two consequences:

- **`HashCache` entries never go stale.** The key determines the bytes. Re-deploying with new code produces a new root hash, so it has nowhere to collide with the old one. There's nothing to invalidate.
- **Rollback is registry-only.** `Services.deploy` mints a new root hash and stores blobs in `HashCache`; `Services.release(name, hash)` is a one-line registry pointer move. The previous hash and its full transitive closure stay in `HashCache` forever, so re-releasing an old hash brings the old behavior back instantly without re-fetching anything. Most blobs are shared across versions (same `printLine` impl, same ability machinery) so the redeploy delta is usually a handful of new `Code` blobs plus one new root `Value`.

Across nodes, the registry's `name → hash` mapping is the only thing that can change underfoot. B asks A's registry on every `Services.call`, so the next request after A re-deploys resolves to the new hash and the fetch chain runs again for whatever's missing.

### Execution routing

`Services.call` defaults to running on the local node's dispatcher. Callers can pass `node: <peer>` to route a call to a specific peer — Unex RPCs `Services.eval_local/2` there, which goes through that node's dispatcher.

### What is shared vs. local

| Component                   | Scope     | Notes                                                                  |
|-----------------------------|-----------|------------------------------------------------------------------------|
| `HashCache` (Values + Code) | Per-node  | Lazily fetched from peers via `SyncServer` on miss; cached forever.    |
| `SourceCache`               | Per-node  | Prettified Unison source by service hash. Populated at deploy time.    |
| `NameCache`                 | Per-node  | Hash → Unison term name. Populated at deploy time.                     |
| `DepsCache`                 | Per-node  | Per-term dependency graph. Populated at deploy time.                   |
| `Services.Registry`         | Per-node  | Owned by deploy node. Peers query on demand via `ask_peers`.           |
| `Unex.Dispatcher`           | Per-node  | Long-lived `ucm run.compiled` with protocol over localhost socket.     |
| Mnesia (Storage cells, OrderedTables) | Per-node  | **Not** cluster-replicated. Writes go to the node that received them.  |
| Config (secrets)            | Per-node  | AES-256-GCM encrypted, stored in Mnesia.                               |
| Scratch (cache)             | Per-node  | ETS, lost on restart.                                                  |
| Log                         | Per-node  | ETS ring buffer.                                                       |
| Blobs                       | Per-node  | Filesystem at `<UNEX_DATA>/blobs/`.                                    |
| Runtime (compilation)       | Per-node  | Each node has its own UCM codebase under `<UNEX_DATA>/runtime_codebase/`. |

Worth flagging: the storage row means cluster-coherent state needs deliberate routing. A counter incremented on B and one incremented on A are two independent counters in two independent Mnesia tables. If you need cluster-wide coherence, route writes through one node (e.g. always call `Services.call(name, node: :"a@…")`) or build replication on top of the storage abilities.

## Server components

```
Unex.Application (supervisor)
  |
  +-- Phoenix.PubSub                  PubSub broker (always started; dashboard subscribes when enabled)
  +-- Unex.Cluster.HashCache          ETS content-addressed cache (Value + Code)
  +-- Unex.Cluster.SourceCache        ETS prettified source by service hash (for dashboard /hash/:id)
  +-- Unex.Cluster.NameCache          ETS hash → Unison term name map (for dashboard)
  +-- Unex.Cluster.DepsCache          ETS per-term dependency graph (for dashboard)
  +-- Unex.Cluster.SyncServer         Cross-node key resolution
  +-- Unex.Services.Registry          Service name -> root-value-hash mapping
  +-- Unex.Abilities.Scratch          ETS ephemeral key-value
  +-- Unex.Abilities.Log              ETS ring buffer
  +-- Unex.Runtime                    Persistent UCM codebase for extraction
  +-- Unex.Dispatcher                 (if start_dispatcher enabled, default on) Long-lived evaluator
  +-- Unex.Cluster.PeerConnector      (if peers configured) Auto-connect with backoff
  +-- Bandit HTTP server              (if API enabled) Serves the HTTP API on :4040
```

### HTTP API

Bearer-token auth is enforced on every endpoint except:

- `GET /health` — always public.
- `GET /<name>` — public if `<name>` resolves to a registered service via `Services.Registry.resolve/1` (matches cluster-wide reachability, not just local). This is the public web endpoint that returns raw stdout as `text/html`.

The API is the interface between Unison programs and the server:

- **Storage** — databases, tables, cells, transactions (Mnesia)
- **Config** — encrypted secrets by environment (Mnesia + AES-256-GCM)
- **Blobs** — binary objects (filesystem)
- **Scratch** — ephemeral cache (ETS)
- **Log** — structured log entries (ETS ring buffer)
- **Bytecode** — push/pull arbitrary `.uc` bundles (legacy; not used by the dispatcher deploy flow)
- **Code** — `GET /code/:termhash` serves a serialized `Code` blob; the dispatcher fetches its missing deps through this endpoint, and the handler itself goes through `SyncServer` so a peer can serve blobs the local node has never seen.
- **Services** — `POST /services/:name/{deploy,release,call}`, `GET /services`, `DELETE /services/:name`, plus the `GET /<name>` public web wrapper above.

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

### Source caching and its limits

At deploy time, `Runtime.extract` captures pretty-printed Unison source
alongside the bytecode. Two passes:

1. **Entry-point source.** The first UCM session runs
   `view <entry_point>` after the extractor finishes. Output is cached
   in `SourceCache` keyed by the service's root hash. This always works
   for the top-level name that was deployed.
2. **Per-term source.** A second UCM session runs `view #<hash>` for
   every hash in the manifest. UCM resolves these against its
   codebase **name map**, not its bytecode-level references. Many
   hashes returned by `Code.dependencies` (anonymous lambdas, component
   sub-references, synthesized bindings) are NOT in the name map —
   UCM responds with "not found in the codebase" and the cache skips
   them.

Consequence: on `/hash/:id`, top-level deployed entry points always
have source; transitive sub-reference hashes often don't. The page
renders an explanatory note in that case. Lifting this limitation
would need either UCM exposing hash→source for raw bytecode references,
or an extractor-level name↔hash dump we can feed back in.
