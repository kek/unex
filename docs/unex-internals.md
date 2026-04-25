# Unex Internals

*An architectural reference for operators and system architects.*

This document describes how Unex is built and why, the operational model it implies, and how it relates to adjacent systems (Unison Cloud, the BEAM, and content-addressed runtimes generally). It assumes familiarity with the existing `docs/architecture.md` and `docs/guide.md`. The goal here is not to repeat those — it is to give the reader the conceptual frame needed to operate Unex confidently and to reason about extending it.

## What Unex actually is

Unex is a BEAM application that evaluates Unison programs. It is not a Unison platform that happens to be implemented in Elixir. The distinction matters operationally: every component except the dispatcher is a first-class citizen of the BEAM, with the supervision, observability, clustering, and upgrade story that implies. Mnesia stores durable data. ETS stores hot caches. Bandit serves HTTP. Erlang's distribution protocol carries cross-node traffic. A long-lived UCM subprocess, supervised by the BEAM, evaluates Unison thunks on demand.

The Unison-shaped pieces — content-addressed code distribution, ability handlers, the dispatcher protocol — are where the platform earns its identity, but they sit on top of the BEAM substrate rather than replacing it. An Elixir-only service running on a Unex node could call `Unex.Cluster.HashCache` and `Unex.Services.Registry` directly without going through Unison at all. The Unison layer is the most interesting consumer of this infrastructure, not the only possible one.

This framing matters because it shapes how operators should think about Unex. Most ops concerns — health checks, log rotation, failover, rolling upgrades, secret rotation, cluster membership — are BEAM problems with BEAM solutions. The Unison-specific operational surface is narrow: UCM version compatibility, dispatcher lifecycle, and the correctness of code extraction. Everything else is a normal Elixir release.

## The two-layer model

The system is divided by an HTTP boundary that carries every interaction between Unison code and platform infrastructure.

On one side, Unison programs use abilities like `Unex.Storage`, `Unex.Config`, and `Unex.Services`. These abilities have no implementation knowledge — they are typed effect declarations. The handlers in `Unex.main` translate each ability request into an HTTP call against the server's API, threading bearer-token authentication through every call.

On the other side, an Elixir application receives those HTTP calls and routes them to BEAM-native components: Mnesia tables for storage, an AES-256-GCM-encrypted store for config secrets, ETS for ephemeral caches, the filesystem for blobs, and (most importantly) the long-lived dispatcher process for code execution.

The boundary's significance is that it is the *only* place where Unison-shaped data crosses into Elixir-shaped data. Inside the Unison side, computations are typed effects with handlers; inside the Elixir side, they are GenServer calls and ETS lookups. HTTP and JSON form the lingua franca that makes the impedance match tractable. This means programs are portable to any Unex deployment without modification — `UNEX_URL` and `UNEX_SECRET` are the only things they read from the environment — and it means an operator debugging a problem can use ordinary HTTP tools (curl, network captures, log grep) to reason about what a Unison program is doing.

## How code reaches a running system

The lifecycle of a deployed service is the central thing to understand, because it touches every interesting component in the system.

A developer writes a Unison program that uses Unex abilities, wraps the entry point in `Unex.main`, and pushes to Unison Share. Share is the code distribution layer; it plays the same role for Unex that it plays for Unison Cloud. The Unex server pulls from Share, and never receives source text or compiled bytecode directly from the client.

When a deploy is triggered, the developer's program calls `Unex.Services.deploy "name" "entryPoint"`. The handler reads `UNEX_PROJECT` from the environment, sends the entry-point name and project to the server, and the server's `Runtime` GenServer takes over.

The Runtime maintains a persistent UCM codebase under `data/runtime_codebase/`, pre-installed with `@unison/base`, `@unison/http`, and `@kek/unex`. On each deploy, it `pull`s the developer's project (incremental — only new hashes are fetched), then writes a small generated `.u` file called `_extractor.u`. This file interpolates the entry-point name and runs under UCM. The extractor's job is to walk the closure of `Value.dependencies` for the named thunk, calling `Code.serialize_v3` on each reachable definition and writing the bytes to disk.

```
pull @myorg/myapp                -- fetch from Unison Share
load /tmp/extract/_extractor.u   -- generated, references mainService by name
run Unex.Extract.main            -- walk deps, write root.value + <hash>.code files
exit
```

Two important details. First, terms whose `Link.Term.toText` begins with `##` are foreign builtins (e.g. `##Nat.+`, `##IO.getEnv.impl.v1`). `Code.serialize_v3` cannot serialize these, and the dispatcher's runtime has them baked in regardless, so the extractor skips them. Second, the walk uses a `seen` list with `List.contains` for membership — adequate for current closure sizes, O(n²) for large ones, easy to upgrade to a `Set` if it ever matters.

The extracted output is two kinds of bytes. There is a single `root.value` file containing `Value.serialize_v4` of the entry-point thunk. And there is one `<hash>.code` file per transitively reachable definition.

The Elixir side reads this output and inserts everything into `HashCache`, the cluster-wide content-addressed store. The root `Value` is keyed by SHA256 of its bytes; each `Code` is keyed by its `Link.Term` text (sans leading `#`). `Services.Registry` then registers the service name pointing at the root-value hash, with the deploy node and timestamp as metadata.

At this point, the service is deployed. No new UCM subprocess starts on call.

## The dispatcher

A single long-lived `ucm run.compiled $UNEX_DISPATCHER` process runs for the lifetime of each Unex node. This is the most distinctive piece of the architecture, and the one most worth understanding deeply.

At startup, `Unex.Dispatcher` listens on `127.0.0.1:0` (an ephemeral port), spawns UCM as a `Port`, and passes the listener's port number to UCM via `UNEX_DISPATCHER_PORT`. The dispatcher's Unison entry point reads that variable, calls `Socket.client` back to localhost, and enters a request loop. Elixir accepts the one incoming connection and the protocol is established.

The protocol is length-prefixed framed bytes in both directions: `<<len::unsigned-big-64, body::binary>>`. Requests carry a `Value.serialize_v4` of a `'{IO, Exception} ()` thunk. Responses carry a single status byte (`0x00` OK, `0xFF` error) followed by an optional UTF-8 message.

The deliberate choice to use a TCP socket rather than the subprocess's stdin/stdout is what makes services able to use stdout normally. Elixir captures stdout off the port separately and accumulates it as the service's output text; the protocol is never corrupted by `printLine`.

When a service call arrives, the flow is this: `Services.Registry` resolves the name to a root-value hash. `SyncServer` resolves the hash to bytes (locally or from a peer, transparently). `Unex.Dispatcher.eval` sends the bytes as a framed request. The Unison side runs:

```
v = Value.deserialize valueBytes
match Value.load v with
  Right thunk -> !thunk
  Left missing ->
    satisfy baseUrl secret [] missing
    retry Value.load
```

`Value.load` returns `Either [Link.Term] ('{IO, Exception} ())`. If every dependency is already in `Code.cache_`, you get `Right thunk` and run it. If some dependencies are missing, you get `Left [hash, ...]` — the list of `Link.Term` hashes the runtime needs. The `satisfy` loop fetches each via `GET /code/:termhash` against `UNEX_URL`, calls `Code.cache_` to register the fetched code in the runtime, and retries `Value.load`. The loop is iterative because freshly-cached code can itself surface new missing dependencies — a fetched `Code` references `Code` of its own.

This is the core mechanism: **the dispatcher is a generic Unison interpreter that fetches code lazily by hash at execution time over HTTP**. The Elixir side never needs to know which specific definitions a service uses. The Unison side never needs the entire closure pre-loaded. They negotiate, hash by hash, until evaluation succeeds.

The result is that the first call to a service pays the cost of fetching its closure, and subsequent calls within the same dispatcher process find everything in `Code.cache_` and evaluate immediately. Cold service calls take milliseconds, not the seconds a `ucm run.compiled` startup would take.

The dispatcher today is single-inflight. Calls queue on the GenServer and run sequentially. This is documented in the source as a future concern; introducing a pool of dispatcher processes is a straightforward extension when concurrent throughput becomes the bottleneck.

## Cluster distribution

Unex nodes form a cluster using BEAM distribution. Each node has its own copies of the per-node components (Mnesia, dispatcher, UCM codebase, blob store, Bandit) and shares two cluster-wide concerns: the `HashCache` of bytecode blobs and the `Services.Registry` of name-to-hash mappings.

`HashCache` is an ETS table on each node. Reads go directly to ETS, with `read_concurrency: true` for parallel access. Writes go through a GenServer to keep ownership clean. When a key is missing locally, `SyncServer` asks every connected peer via `GenServer.call({SyncServer, peer}, {:fetch_local, hash})`. Anything retrieved from a peer is cached locally, so each node warms incrementally as it serves traffic.

`Services.Registry` follows the same pattern: local ETS first, peer fallback on miss. A registry entry records the deploy node alongside the hash, so callers know which node originally served the deployment, but execution is not pinned there.

The composition of these two pieces gives transparent cluster-wide availability. A service deployed on node A and called on node B follows this path: B's registry misses locally, asks A, gets `{hash, node_a, deployed_at}`. B's `SyncServer` then resolves the root-value hash, missing locally and fetching from A. B's dispatcher receives the bytes, deserializes, and calls `Value.load`. The dispatcher needs `Code` blobs, hits its own `UNEX_URL` (which is always `http://localhost:4040` or whatever `api_port` is set to), the local API routes through `CodeController → SyncServer.resolve`, which fans out to peers as needed. After the first call, the relevant code is cached locally on B and the round-trip disappears.

Operators should note that this means deploys do not need to be pushed to all nodes manually. A single deploy on any node makes the service available cluster-wide; the first call from each other node pulls the code on demand. This is convenient but worth understanding when reasoning about latency: the first invocation on each node is slower than steady state.

For execution routing, `Services.call` defaults to running on the local node's dispatcher. Operators can pass `node:` to pin execution to a specific peer — Unex RPCs `Services.eval_local/2` there, which goes through that node's dispatcher. This is the seam where deliberate placement (CPU affinity, data locality, blast-radius isolation) can be expressed.

## Storage, config, and other abilities

`Unex.Storage` exposes databases, tables, ordered tables, cells (single-value slots), and transactions, all backed by Mnesia. Each node has its own Mnesia instance. The Mnesia layer is not currently replicated across the cluster — storage state is per-node — which is a deliberate simplification that keeps the consistency model legible. Operators who want HA storage today should run a single storage node and replicate at the storage layer (Mnesia's built-in replication, or by treating Unex as a stateless front for an external store).

`Unex.Config` provides AES-256-GCM-encrypted secret storage, scoped by environment. The encryption key is `UNEX_CONFIG_KEY` — an auto-generated value that should be persisted across restarts to keep secrets readable. Config values are stored in Mnesia alongside other state.

`Unex.Blobs` writes binary objects to the filesystem under `data/blobs/`. Per-node, like Mnesia.

`Unex.Scratch` is an ETS table for ephemeral key-value data. Lost on restart by design.

`Unex.Log` is an ETS ring buffer for structured log entries. Also ephemeral.

The pattern here is consistent: Unex provides storage primitives at several durability and replication levels, and the operator chooses which to use based on the workload. Per-node ephemeral storage covers a lot of working-set use cases without forcing the cost of consistency on every operation.

## Operating the system

A few operational properties follow from the architecture above.

**Startup ordering.** The supervision tree is ordered such that `HashCache` and `SyncServer` start before the `Runtime` (which needs to write extracted blobs into the cache) and the `Dispatcher` (which needs to fetch them). The HTTP server starts last, after the cluster joining is in flight. Operators changing the supervision tree should preserve this ordering.

**Dispatcher bootstrap.** `Unex.Dispatcher` starts only if `dispatcher.uc` exists at `UNEX_DISPATCHER` (or the default `data/dispatcher.uc`). This file is produced by `mix unex.compile_dispatcher` and is tied to the UCM version that built it. In production images the bundle lives outside the data volume — typically `/app/dispatcher.uc` — so a host-mounted `/app/data` does not shadow the image-baked artifact. The Dockerfile shares a single `UCM_VERSION` build arg between the build stage (which compiles the bundle) and the runtime stage (which runs `ucm run.compiled` against it). This pinning is load-bearing; mismatched UCM versions produce dispatcher startup failures.

**Cluster joining.** `Unex.Cluster.PeerConnector` reads `UNEX_PEERS` and attempts BEAM distribution connections with backoff. The cookie (`UNEX_COOKIE`) and node name (`UNEX_NODE`) must be set consistently across the cluster. Standard BEAM distribution rules apply: name resolution, port reachability, and cookie matching all need to be in place for a node to join.

**Authentication.** Every API endpoint except `/health` requires a bearer token. `UNEX_SECRET` is auto-generated on first run and printed to stdout; persisting it across restarts requires setting the variable explicitly. The dispatcher uses the same secret for its `/code/:termhash` callbacks, so the token is functionally a cluster-wide capability — protect it accordingly.

**Observability.** Dispatcher subprocess output is captured and tagged `[dispatcher/stdout]` in the BEAM logs when no request is in flight; during a request it is accumulated as the service's result. UCM-side errors come through as `0xFF` framed responses with UTF-8 messages, which surface as `{:error, msg}` in the Elixir caller. There is no built-in metrics endpoint today; adding one is a normal Elixir telemetry exercise.

## What about UCM version skew

This question comes up because the dispatcher bundle is keyed on the UCM version that built it, and `Value`/`Code` serialization is part of UCM rather than the language proper. The `_v3`, `_v4` suffixes on `Code.serialize_v3` and `Value.serialize_v4` are visible evidence that older serializers are kept around so newer UCM versions can still deserialize older bytes.

In practice this means the system is robust to minor-version skew across nodes during a rolling upgrade, because each UCM version retains backward-compat readers. The failure case is on a much longer timescale — when a serializer version is eventually removed entirely, blobs serialized only in that format become unreadable. Operators should expect to occasionally walk `HashCache`, deserialize-with-old, reserialize-with-new, replace. There is no built-in tool for this today.

A second class of compatibility concern is the `@kek/unex` library version baked into deployed services. When a service is extracted, the closure includes the version of `Unex.Storage.handler` and friends that was in scope at deploy time. If those handlers change shape — say, a JSON field is renamed in a request body — old deployed services keep speaking the old shape, even after the server-side endpoint has changed. Operators changing the wire schema should plan to redeploy every affected service. A `Unex.redeploy` tool that re-extracts all registered services against a target library hash is a reasonable extension when this becomes painful.

## Comparison with Unison Cloud

Unex and Unison Cloud overlap in surface area, and the comparison is worth being precise about because it shapes operator expectations.

Both systems use Unison Share as the source of code, both store deployed services as content-addressed blobs, and both use the same `Value.load` / `Code.cache_` machinery to evaluate thunks while fetching dependencies on demand. The execution model — root `Value` plus lazy hash fetch — is identical in shape, because both systems are downstream of Unison's content-addressed model.

The visible differences are these.

Cloud is a hosted product. The whole pitch is that the network is the computer and you do not have to think about machines. Unex's pitch, implicit in its choice of BEAM, Mnesia, bearer tokens, and a Dockerfile, is the opposite: these are machines, you operate them, and you want the programs running on them to have the nice properties of content-addressing and typed effects without giving up control of the substrate.

Cloud supports thunk submission from inside a running program — `Cloud.submit` and friends, where a Unison computation can construct a thunk at runtime and ask the platform to run it elsewhere. Unex today does not. `Unex.Services.deploy` takes an entry-point name, not a thunk value, because the extractor is a separate UCM subprocess that needs a name to call `Value.value <name>`. Closing this gap requires an extension to the dispatcher protocol: a frame that says "please serialize this thunk and store it under its hash." All the pieces exist; it is unbuilt rather than impossible. This is the most consequential expressiveness gap relative to Cloud and the most natural future direction for the project.

Cloud has more tooling. Bulk re-serialization, compatibility test suites against a deployed corpus, observability and UI, replicated storage with consistency semantics, scheduling — these are all features of a maturing product, and Unex has none of them yet. Operators should not expect parity. They should expect the BEAM's operational primitives to cover most of the gap (supervision, distribution, hot upgrades, Mnesia replication, telemetry libraries) at the cost of building integration glue themselves.

The architectural difference that matters is this: Cloud chose to build a Unison-native ops platform from scratch. Unex chose to embed Unison's runtime into an existing ops platform (the BEAM). Both are coherent strategies. The Unex bet is that the cost of building bespoke ops infrastructure exceeds the cost of bridging two runtimes via a localhost socket, given that the BEAM already solves so many of the same problems. Operators evaluating Unex are implicitly placing the same bet.

## Where the architecture is generalizable

The dispatcher pattern — a long-lived non-BEAM language runtime as a supervised subprocess, communicating with the BEAM via framed sockets, with content-addressed lazy loading over HTTP — is not Unison-specific. The same shape would work for an embedded Racket, a Wasm module, a Python interpreter, or any other runtime where you want to keep a process alive for state and warm caches but have the BEAM own lifecycle and supervision.

What makes the pattern click cleanly for Unison is content-addressing: the `Value.load` / `Code.cache_` protocol gives you a structured way to negotiate dependencies hash by hash, without either side needing to know the full closure in advance. For other runtimes you would need to invent that protocol yourself, or accept that the embedded process needs all its code at startup. But the supervision-and-protocol skeleton — accept-once on a localhost listener, frame protocol, separate stdout capture, exit-status handling — is reusable as a BEAM idiom for any embedded language runtime. Future evolution of Unex may make this skeleton its own library; it would be a useful contribution to the BEAM ecosystem independent of Unison.

## Summary

Unex is a self-hosted BEAM application that runs Unison services as content-addressed thunks. It uses HTTP for the language boundary, Mnesia and ETS for storage, Erlang distribution for clustering, and a long-lived UCM subprocess with a localhost framed protocol for evaluation. It deploys services by extracting their dependency closure from a UCM codebase and storing the bytes in a cluster-wide cache; it executes them by handing the root `Value` to the dispatcher, which lazily fetches whatever it needs over HTTP.

It is not a Unison Cloud clone. It overlaps with Cloud's surface because both are downstream of the same language design, but its identity is distinct: it is a Unison-enabled BEAM ops platform for operators who want to run their own infrastructure and treat Unison's content-addressed semantics as one nice property among many. The architectural choices reflect that identity. So should the operational mental model.
