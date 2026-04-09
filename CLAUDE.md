# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Unex

An ops platform for [Unison](https://www.unison-lang.org/) programs. Two-layer architecture:
- **Outer (Elixir/BEAM):** HTTP API, Mnesia storage, ETS caches, AES-256-GCM encrypted config, filesystem blob storage, BEAM distribution clustering, UCM subprocess management
- **Inner (Unison):** Programs use idiomatic abilities (`Unex.Storage`, `Unex.Config`, `Unex.Blobs`, `Unex.Scratch`, `Unex.Log`, `Unex.Remote`, `Unex.Services`); handlers in `unison/` translate ability calls to HTTP requests against the Elixir API

## Build & Run Commands

```bash
mix deps.get                    # Install dependencies
mix unex.start                # Start server (API on :4040)
mix test                        # Run all tests
mix test --trace                # Verbose test output
mix test test/path/file.exs     # Single test file
mix test test/path/file.exs:42  # Single test (line number)
MIX_ENV=prod mix release        # Build production release
```

Clustering: `UNEX_NODE=a UNEX_COOKIE=secret UNEX_PORT=4040 UNEX_PEERS=b@host mix unex.start`

## Dependencies

Minimal: Plug (HTTP middleware), Bandit (HTTP server), Jason (JSON). No external database drivers — storage is Mnesia (built into BEAM). Requires Elixir 1.17+ and UCM binary on PATH.

## Architecture

### Supervision tree (`Unex.Application`)
Always started: `HashCache`, `SyncServer`, `Services.Registry`, `Scratch`, `Log`. Conditionally started: `PeerConnector` (when peers configured), Bandit HTTP server (when `:start_api` is true).

### Execution flow
`Unex.eval/2` and `Unex.compile_and_run/2` are the top-level API. Both create an ephemeral `Workspace` (isolated Unison codebase in tmp), then either run source directly via `Runner.run_file` or compile to `.uc` bytecode via `Compiler` first. Bytecode is cached in `HashCache` by SHA256.

### Storage layer (`lib/unex/storage/`)
All backed by Mnesia disc copies. `Schema` initializes tables on boot. `Database` is a logical namespace. `OrderedTable` provides sorted key-value (Mnesia ordered_set). `Cell` stores single named values. `Transaction` wraps multiple ops atomically.

### Abilities (`lib/unex/abilities/`)
Each maps to a Unison ability and an API controller: `Config` (AES-256-GCM encrypted secrets by environment), `Scratch` (ETS ephemeral cache), `Log` (ETS ring buffer), `Blobs` (filesystem at `data/blobs/`).

### Clustering (`lib/unex/cluster/`)
`HashCache` stores bytecode in ETS keyed by SHA256. `SyncServer` resolves hashes across nodes via RPC. `PeerConnector` auto-connects with exponential backoff. `Remote` coordinates cross-node execution.

### HTTP API (`lib/unex/api/`)
Plug router dispatches to controllers. `Auth` plug enforces bearer token (`Authorization: Bearer <secret>`) on all routes except `/health`. Each controller handles JSON encoding/decoding for its domain. API runs on Bandit, default port 4040.

### Unison ability library (`unison/`)
`.u` files define abilities and HTTP-backed handlers. All handlers take `baseUrl` and `secret` parameters for authenticated HTTP calls. `Main.u` composes all handlers. `Examples/` has working programs. These files are meant to be copied into Unison projects.

## Configuration

Resolved in order (first wins): env vars → config file (`UNEX_CONFIG`) → defaults. Key env vars: `UNEX_NODE`, `UNEX_COOKIE`, `UNEX_PORT` (default 4040), `UNEX_DATA` (default `./data`), `UNEX_PEERS`, `UNEX_SECRET` (auto-generated if not set), `UNEX_CONFIG_KEY`, `UCM_PATH`.

## Test Structure

- `test/unex/` — unit tests (one module per test file)
- `test/integration/` — full-stack tests that start Mnesia + Bandit and exercise real Unison programs
- Test config (`config/test.exs`): API auto-start disabled, ephemeral Mnesia dirs, hardcoded encryption key
