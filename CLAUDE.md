# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Unex

An ops platform for [Unison](https://www.unison-lang.org/) programs. Two-layer architecture:
- **Outer (Elixir/BEAM):** HTTP API, Mnesia storage, ETS caches, AES-256-GCM encrypted config, filesystem blob storage, BEAM distribution clustering, UCM subprocess management
- **Inner (Unison):** Programs use idiomatic abilities (`Unex.Storage`, `Unex.Config`, `Unex.Blobs`, `Unex.Scratch`, `Unex.Log`, `Unex.Remote`, `Unex.Services`); handlers in `unison/` translate ability calls to HTTP requests against the Elixir API

## Build & Run Commands

```bash
mix deps.get                    # Install dependencies
iex -S mix run --no-halt        # Start server (API on :4040), drop into iex
mix run --no-halt               # Same, no shell
mix test                        # Run all tests
mix test --trace                # Verbose test output
mix test test/path/file.exs     # Single test file
mix test test/path/file.exs:42  # Single test (line number)
MIX_ENV=prod mix release        # Build production release
```

Clustering uses standard BEAM distribution flags:
`iex --name a@127.0.0.1 --cookie secret -S mix run --no-halt` (set
`UNEX_PEERS=b@127.0.0.1,...` so the node connects on boot).

## Dependencies

Core runtime: Plug (HTTP middleware), Bandit (HTTP server), Jason (JSON). No
external database drivers — storage is Mnesia (built into BEAM). Requires
Elixir 1.19+ and UCM binary on PATH.

Dashboard (opt-in, same BEAM node): Phoenix 1.7, Phoenix LiveView 1.0,
Phoenix LiveDashboard, Phoenix.PubSub, telemetry_metrics, telemetry_poller.
Asset pipeline uses esbuild and tailwind via Mix tasks.

## Architecture

### Supervision tree (`Unex.Application`)
Always started: `HashCache`, `SyncServer`, `Services.Registry`, `Scratch`, `Log`, `Runtime`. Conditionally started: `Dispatcher` (when `:start_dispatcher` is true AND `dispatcher.uc` exists), `PeerConnector` (when peers configured), Bandit HTTP server (when `:start_api` is true).

### Execution flow
`Unex.eval/2` and `Unex.compile_and_run/2` are the top-level API for one-shot source runs. Both create an ephemeral `Workspace` (isolated Unison codebase in tmp), then either run source directly via `Runner.run_file` or compile to `.uc` bytecode via `Compiler` first.

Deployed services use a different path. At deploy time, `Runtime.extract/2` pulls the project into the persistent codebase and generates a per-deploy extractor `.u` that runs under `ucm run.file`, emitting a serialized root `Value` plus every transitively reachable `Code` (one file per `Link.Term` hash). Elixir stores the root value in `HashCache` by SHA256 and each `Code` blob under its `Link.Term` hash. At call time, `Services.call` hands the root value bytes to `Unex.Dispatcher` — a long-lived `ucm run.compiled dispatcher.uc` subprocess that speaks a length-prefixed protocol over a localhost TCP socket. The dispatcher fetches missing `Code` via HTTP `GET /code/:termhash` back to Elixir, `Code.cache_`s it, and evaluates the thunk. Stdout from the subprocess is captured and returned as the service's result; the protocol socket is separate so user `printLine` doesn't corrupt it.

### Storage layer (`lib/unex/storage/`)
All backed by Mnesia disc copies. `Schema` initializes tables on boot. `Database` is a logical namespace. `OrderedTable` provides sorted key-value (Mnesia ordered_set). `Cell` stores single named values. `Transaction` wraps multiple ops atomically.

### Abilities (`lib/unex/abilities/`)
Each maps to a Unison ability and an API controller: `Config` (AES-256-GCM encrypted secrets by environment), `Scratch` (ETS ephemeral cache), `Log` (ETS ring buffer), `Blobs` (filesystem at `data/blobs/`).

### Clustering (`lib/unex/cluster/`)
`HashCache` stores content-addressed blobs in ETS — root `Value` bytes keyed by SHA256 and per-term `Code` bytes keyed by `Link.Term` hash. `SyncServer` resolves keys across nodes via RPC. `PeerConnector` auto-connects with exponential backoff. `Remote` (legacy) still exists but `Services.call` drives cross-node execution directly via `:rpc.call` to `Services.eval_local/2` on the target node.

### HTTP API (`lib/unex/api/`)
Plug router dispatches to controllers. `Auth` plug enforces bearer token (`Authorization: Bearer <secret>`) on all routes except `/health`. Each controller handles JSON encoding/decoding for its domain. API runs on Bandit, default port 4040.

### Unison ability library (`unison/`)
`.u` files define abilities and HTTP-backed handlers. All handlers take `baseUrl` and `secret` parameters for authenticated HTTP calls. `Main.u` composes all handlers. `Examples/` has working programs. These files are meant to be copied into Unison projects.
`Services.u` deploy handler sends the function name + Share project to the server. The server's `Runtime` GenServer pulls from Unison Share and runs a generated extractor, storing the serialized `Value` + transitive `Code` blobs in `HashCache`. Service entry points must be thunks of type `'{IO, Exception} ()` (the dispatcher runs them for side effects and captures stdout as the result).

`Dispatcher.u` is the long-lived evaluator that runs as `ucm run.compiled dispatcher.uc` — rebuild with `mix unex.compile_dispatcher` after changing it.

### Dashboard (`lib/unex_dashboard/`)
Opt-in Phoenix LiveView subsystem in the same BEAM node. Subscribes to PubSub
topics published by core. Core → dashboard dependency is one-way and enforced
by a boundary test. See `docs/architecture.md#dashboard-opt-in`.

## Configuration

Resolved in order (first wins): env vars → config file (`UNEX_CONFIG`) → defaults. Key env vars: `UNEX_NODE`, `UNEX_COOKIE`, `UNEX_PORT` (default 4040), `UNEX_DATA` (default `./data`), `UNEX_PEERS`, `UNEX_SECRET` (auto-generated if not set), `UNEX_CONFIG_KEY`, `UCM_PATH`, `UNEX_DISPATCHER` (path to `dispatcher.uc`; defaults to `<UNEX_DATA>/dispatcher.uc`, set to a path outside the data volume in production).

Dashboard env vars:
- `UNEX_DASHBOARD` — set to `1`/`true` to enable the dashboard subsystem
- `UNEX_DASHBOARD_PORT` — dashboard HTTP port (default 4041)
- `UNEX_DASHBOARD_HOST` — bind address (default `127.0.0.1`; set to `0.0.0.0` to expose on all interfaces)
- `UNEX_DASHBOARD_USER`, `UNEX_DASHBOARD_PASS` — Basic Auth credentials

## Test Structure

- `test/unex/` — unit tests (one module per test file)
- `test/integration/` — full-stack tests that start Mnesia + Bandit and exercise real Unison programs
- Test config (`config/test.exs`): API auto-start disabled, ephemeral Mnesia dirs, hardcoded encryption key
