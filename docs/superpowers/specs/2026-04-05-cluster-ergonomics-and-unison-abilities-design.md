# Cluster Ergonomics & Unison Ability Library — Design Spec

## Overview

Two independent improvements to Unex:

1. **Cluster Ergonomics (Plan 7)** — zero-config single-node startup, env-var-driven cluster configuration, auto-peer-connect, Mix release for production
2. **Unison Ability Library (Plan 8)** — proper Unison ability definitions with HTTP-backed handlers for all seven abilities, so Unison programs use idiomatic `handle ... with` patterns instead of raw HTTP calls

---

## Plan 7: Cluster Ergonomics

### Goal

Replace the current manual multi-terminal, iex-flag, Node.connect workflow with: `mix unex.start` for dev, `./bin/unex start` for production. Single-node works with zero config. Clustering requires only setting a few env vars.

### Config Resolution

Lookup order (first wins):

1. **Environment variables** — always override everything
2. **Config file** — pointed to by `UNEX_CONFIG` env var, or found at `~/.config/unex/config.exs` / `/etc/unex/config.exs`
3. **Built-in defaults** — single-node, port 4040, data in `./data/`

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UNEX_NODE` | *(none — no distribution)* | Node name. Short name (e.g., `a`) uses `--sname`, FQDN (e.g., `a@10.0.1.5`) uses `--name` |
| `UNEX_COOKIE` | *(none)* | Cluster auth cookie. Required if `UNEX_NODE` is set |
| `UNEX_PORT` | `4040` | HTTP API port |
| `UNEX_DATA` | `./data` | Base directory for Mnesia and blobs |
| `UNEX_PEERS` | *(none)* | Comma-separated list of peer nodes to auto-connect (e.g., `b@10.0.1.2,c@10.0.1.3`) |
| `UNEX_CONFIG_KEY` | *(none — generated at startup)* | AES-256-GCM encryption key for Config secrets |
| `UNEX_CONFIG` | *(none)* | Path to config file |
| `UCM_PATH` | `ucm` | Path to UCM binary |

### Config File Format

Optional. For operators managing multiple nodes who prefer a file over env vars:

```elixir
# /etc/unex/node-a.exs
import Config

config :unex,
  node_name: "a",
  cookie: "unex_secret",
  api_port: 4040,
  data_dir: "/var/data/unex",
  peers: ["b@10.0.1.2", "c@10.0.1.3"],
  config_encryption_key: "base64-encoded-key-here"
```

Env vars always override values from the config file.

### Encryption Key Behavior

- If `UNEX_CONFIG_KEY` is not set and no config file provides one: generate a random 32-byte key, base64-encode it, and print to stdout:
  ```
  [unex] No encryption key configured. Generated: <base64>
  [unex] Set UNEX_CONFIG_KEY to persist this key across restarts.
  [unex] WARNING: If the key changes, existing encrypted Config values become unreadable.
  ```
- No default key is ever committed to the codebase.

### PeerConnector GenServer

A new supervised process that:
1. Parses `UNEX_PEERS` into a list of node atoms
2. Attempts `Node.connect/1` to each peer
3. On failure, retries with exponential backoff (1s, 2s, 4s, ... capped at 30s)
4. Logs connection success/failure
5. Periodically re-checks (every 30s) to handle peers that come up later
6. Only starts if `UNEX_NODE` is set (distribution enabled)

### Validation

- If `UNEX_NODE` is set but `UNEX_COOKIE` is not: startup fails with a clear error message: `"UNEX_COOKIE is required when UNEX_NODE is set"`
- If `UNEX_PEERS` is set but `UNEX_NODE` is not: startup fails: `"UNEX_NODE is required when UNEX_PEERS is set"`

### Mix Task: `mix unex.start`

A Mix task that:
1. Reads config (env vars > config file > defaults)
2. Validates config (see above)
3. If `UNEX_NODE` is set, re-execs the command with distribution flags — since VM flags can't be changed after the BEAM starts, the task calls `System.cmd("elixir", ["--sname", name, "--cookie", cookie, "-S", "mix", "run", "--no-halt"])` or equivalent
4. Starts the application with API enabled
5. Drops into IEx

```bash
# Zero config — single node, port 4040
mix unex.start

# Cluster node
UNEX_NODE=a UNEX_COOKIE=secret UNEX_PEERS=b@host mix unex.start

# Custom config file
mix unex.start --config /path/to/config.exs
```

### Mix Release

`MIX_ENV=prod mix release` produces a standalone `unex` binary.

- `rel/env.sh.eex` translates `UNEX_NODE` and `UNEX_COOKIE` into `--sname`/`--name` and `--cookie` VM flags
- `config/runtime.exs` handles all other config resolution
- Same env vars work for both dev and production

```bash
# Build
MIX_ENV=prod mix release

# Single node
./bin/unex start

# Cluster node
UNEX_NODE=a UNEX_COOKIE=secret UNEX_PEERS=b@host ./bin/unex start

# Attach to running node
./bin/unex remote
```

### Defaults (Zero Config)

When nothing is configured:
- No distribution (single-node mode)
- Port 4040
- Data stored in `./data/mnesia` and `./data/blobs`
- Random encryption key generated and printed
- API starts automatically

### Files

```
config/
  runtime.exs                    -- rewrite: unified config resolution
rel/
  env.sh.eex                    -- VM flag injection for release
  vm.args.eex                   -- BEAM VM args template
lib/unex/
  cluster/peer_connector.ex     -- auto-connect GenServer
  config_resolver.ex            -- env var > file > default resolution logic
  application.ex                -- modify: add PeerConnector, always start API
mix.exs                         -- add release config
config.example.exs              -- reference config file (not loaded by default)
```

### What Changes from Current Behavior

- `start_api` config flag removed — API always starts (controlled by whether the app is running)
- `mnesia_dir` and `blobs_dir` derived from `UNEX_DATA` by default (can still be set individually)
- Application startup auto-connects to peers instead of manual `Node.connect`
- `config/test.exs` still disables API and distribution for tests

---

## Plan 8: Unison Ability Library

### Goal

Provide a Unison library where programs are written against abstract abilities (`Unex.Storage`, `Unex.Config`, etc.) and the Unex handler translates operations to HTTP calls. Programs look like:

```unison
myApp : '{Unex.Storage, Unex.Config, IO, Exception} ()
myApp = do
  Unex.Config.set "prod" "api_key" "sk-secret"
  Unex.Storage.write "mydb" "users" "alice" "{\"role\":\"admin\"}"
  val = Unex.Storage.read "mydb" "users" "alice"
  printLine (Optional.getOrElse "not found" val)

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" myApp
```

### Ability Definitions

#### Unex.Storage

```unison
unique ability Unex.Storage where
  createDatabase : Text -> ()
  listDatabases : [Text]
  createTable : Text -> Text -> ()
  write : Text -> Text -> Text -> Text -> ()
  read : Text -> Text -> Text -> Optional Text
  delete : Text -> Text -> Text -> ()
  scan : Text -> Text -> Text -> Text -> [(Text, Text)]
  writeCell : Text -> Text -> Text -> ()
  readCell : Text -> Text -> Optional Text
  tx : Text -> [TxOp] -> ()

structural type TxOp
  = WriteTable Text Text Text    -- table, key, value
  | WriteCell Text Text          -- name, value
```

#### Unex.Config

```unison
unique ability Unex.Config where
  set : Text -> Text -> Text -> ()
  get : Text -> Text -> Optional Text
  delete : Text -> Text -> ()
  list : Text -> [Text]
```

#### Unex.Blobs

```unison
unique ability Unex.Blobs where
  write : Text -> Text -> Bytes -> ()
  read : Text -> Text -> Optional Bytes
  delete : Text -> Text -> ()
  list : Text -> Text -> [Text]
```

#### Unex.Scratch

```unison
unique ability Unex.Scratch where
  put : Text -> Text -> ()
  get : Text -> Optional Text
  delete : Text -> ()
```

#### Unex.Log

```unison
unique ability Unex.Log where
  info : Text -> ()
  error : Text -> ()
  warn : Text -> ()
  recent : Nat -> [LogEntry]

structural type LogEntry = { level : Text, message : Text, timestamp : Text, metadata : Text }
```

#### Unex.Remote

```unison
unique ability Unex.Remote where
  execute : Text -> Text
  submit : Text -> Text
```

#### Unex.Services

```unison
unique ability Unex.Services where
  deploy : Text -> Text -> Text
  call : Text -> Text
  list : [ServiceInfo]
  undeploy : Text -> ()

structural type ServiceInfo = { name : Text, hash : Text, node : Text }
```

### Handler Architecture

Each ability gets a handler function that pattern-matches on the ability's operations and makes HTTP calls:

```unison
Unex.Storage.handler : Text -> Request {Unex.Storage} a -> {Http, Threads, IO, Exception} a
Unex.Storage.handler baseUrl = cases
  { Unex.Storage.write db table key value -> k } ->
    _ = postJson (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/write")
          (toJson [("key", key), ("value", value)])
    handle k () with Unex.Storage.handler baseUrl
  { Unex.Storage.read db table key -> k } ->
    resp = getJson (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/read/" ++ key)
    val = parseOptionalValue resp
    handle k val with Unex.Storage.handler baseUrl
  -- ... remaining operations ...
  { a } -> a
```

### Top-Level Combinator

`Unex.main` composes all handlers:

```unison
Unex.main : Text -> '{Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch, Unex.Log, Unex.Remote, Unex.Services, IO, Exception} a -> '{IO, Exception} a
Unex.main baseUrl program = do
  Threads.run do Http.run do
    handle
      (handle
        (handle
          (handle
            (handle
              (handle
                (handle !program
                  with Unex.Storage.handler baseUrl)
                with Unex.Config.handler baseUrl)
              with Unex.Blobs.handler baseUrl)
            with Unex.Scratch.handler baseUrl)
          with Unex.Log.handler baseUrl)
        with Unex.Remote.handler baseUrl)
      with Unex.Services.handler baseUrl
```

Users who only need a subset can compose handlers individually:

```unison
myMain = do
  Threads.run do Http.run do
    handle !myApp with Unex.Storage.handler "http://localhost:4040"
```

### Shared HTTP Helpers

A helpers module provides JSON construction and HTTP plumbing used by all handlers:

```unison
Unex.Http.postJson : Text -> Text -> {Http, Threads, IO, Exception} HttpResponse
Unex.Http.getJson : Text -> {Http, Threads, IO, Exception} Text
Unex.Http.deleteReq : Text -> {Http, Threads, IO, Exception} HttpResponse
Unex.Http.toJson : [(Text, Text)] -> Text
Unex.Http.parseOptionalValue : Text -> Optional Text
```

### File Structure

```
unison/
  Unex/
    Storage.u           -- Unex.Storage ability + handler
    Config.u            -- Unex.Config ability + handler
    Blobs.u             -- Unex.Blobs ability + handler
    Scratch.u           -- Unex.Scratch ability + handler
    Log.u               -- Unex.Log ability + handler
    Remote.u            -- Unex.Remote ability + handler
    Services.u          -- Unex.Services ability + handler
    Http/Helpers.u      -- shared HTTP + JSON utilities
  Main.u                -- Unex.main combinator
  Examples/
    BasicStorage.u      -- example: write/read/scan
    ConfigAndSecrets.u  -- example: config management
    FullApp.u           -- example: using all abilities together
```

### Testing Strategy

Each handler is testable by:
1. Starting a Unex server (`mix unex.start`)
2. Running the Unison program via UCM (`run main`)
3. Verifying output

Example programs in `unison/Examples/` serve as both documentation and integration tests.

For unit testing within Unison, users can write mock handlers:

```unison
mockStorage : Request {Unex.Storage} a -> a
mockStorage = cases
  { Unex.Storage.read _ _ _ -> k } -> handle k (Some "mock-value") with mockStorage
  { Unex.Storage.write _ _ _ _ -> k } -> handle k () with mockStorage
  { a } -> a
```

### What This Doesn't Cover

- **Automatic UCM project setup** — users manually create their Unison project and copy/install the library. A future `mix unex.init.unison` task could automate this.
- **Binary serialization** — values are JSON text over HTTP, not Unison's native serialization format. This is a pragmatic choice; native serialization would require understanding UCM's wire format.
- **Streaming** — no Volturno/Seq equivalent. Operations are request-response.

---

## Build Order

1. **Plan 7: Cluster Ergonomics** — improves operator experience for everything
2. **Plan 8: Unison Ability Library** — builds on the easy-to-start cluster

They share no code. Plan 8 only needs Plan 7 to be done so the README examples say `mix unex.start` instead of the old manual process.
