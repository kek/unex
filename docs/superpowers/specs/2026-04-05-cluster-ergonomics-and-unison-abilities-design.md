# Cluster Ergonomics & Unison Ability Library — Design Spec

## Overview

Two independent improvements to Uniops:

1. **Cluster Ergonomics (Plan 7)** — zero-config single-node startup, env-var-driven cluster configuration, auto-peer-connect, Mix release for production
2. **Unison Ability Library (Plan 8)** — proper Unison ability definitions with HTTP-backed handlers for all seven abilities, so Unison programs use idiomatic `handle ... with` patterns instead of raw HTTP calls

---

## Plan 7: Cluster Ergonomics

### Goal

Replace the current manual multi-terminal, iex-flag, Node.connect workflow with: `mix uniops.start` for dev, `./bin/uniops start` for production. Single-node works with zero config. Clustering requires only setting a few env vars.

### Config Resolution

Lookup order (first wins):

1. **Environment variables** — always override everything
2. **Config file** — pointed to by `UNIOPS_CONFIG` env var, or found at `~/.config/uniops/config.exs` / `/etc/uniops/config.exs`
3. **Built-in defaults** — single-node, port 4040, data in `./data/`

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UNIOPS_NODE` | *(none — no distribution)* | Node name. Short name (e.g., `a`) uses `--sname`, FQDN (e.g., `a@10.0.1.5`) uses `--name` |
| `UNIOPS_COOKIE` | *(none)* | Cluster auth cookie. Required if `UNIOPS_NODE` is set |
| `UNIOPS_PORT` | `4040` | HTTP API port |
| `UNIOPS_DATA` | `./data` | Base directory for Mnesia and blobs |
| `UNIOPS_PEERS` | *(none)* | Comma-separated list of peer nodes to auto-connect (e.g., `b@10.0.1.2,c@10.0.1.3`) |
| `UNIOPS_CONFIG_KEY` | *(none — generated at startup)* | AES-256-GCM encryption key for Config secrets |
| `UNIOPS_CONFIG` | *(none)* | Path to config file |
| `UCM_PATH` | `ucm` | Path to UCM binary |

### Config File Format

Optional. For operators managing multiple nodes who prefer a file over env vars:

```elixir
# /etc/uniops/node-a.exs
import Config

config :uniops,
  node_name: "a",
  cookie: "uniops_secret",
  api_port: 4040,
  data_dir: "/var/data/uniops",
  peers: ["b@10.0.1.2", "c@10.0.1.3"],
  config_encryption_key: "base64-encoded-key-here"
```

Env vars always override values from the config file.

### Encryption Key Behavior

- If `UNIOPS_CONFIG_KEY` is not set and no config file provides one: generate a random 32-byte key, base64-encode it, and print to stdout:
  ```
  [uniops] No encryption key configured. Generated: <base64>
  [uniops] Set UNIOPS_CONFIG_KEY to persist this key across restarts.
  [uniops] WARNING: If the key changes, existing encrypted Config values become unreadable.
  ```
- No default key is ever committed to the codebase.

### PeerConnector GenServer

A new supervised process that:
1. Parses `UNIOPS_PEERS` into a list of node atoms
2. Attempts `Node.connect/1` to each peer
3. On failure, retries with exponential backoff (1s, 2s, 4s, ... capped at 30s)
4. Logs connection success/failure
5. Periodically re-checks (every 30s) to handle peers that come up later
6. Only starts if `UNIOPS_NODE` is set (distribution enabled)

### Validation

- If `UNIOPS_NODE` is set but `UNIOPS_COOKIE` is not: startup fails with a clear error message: `"UNIOPS_COOKIE is required when UNIOPS_NODE is set"`
- If `UNIOPS_PEERS` is set but `UNIOPS_NODE` is not: startup fails: `"UNIOPS_NODE is required when UNIOPS_PEERS is set"`

### Mix Task: `mix uniops.start`

A Mix task that:
1. Reads config (env vars > config file > defaults)
2. Validates config (see above)
3. If `UNIOPS_NODE` is set, re-execs the command with distribution flags — since VM flags can't be changed after the BEAM starts, the task calls `System.cmd("elixir", ["--sname", name, "--cookie", cookie, "-S", "mix", "run", "--no-halt"])` or equivalent
4. Starts the application with API enabled
5. Drops into IEx

```bash
# Zero config — single node, port 4040
mix uniops.start

# Cluster node
UNIOPS_NODE=a UNIOPS_COOKIE=secret UNIOPS_PEERS=b@host mix uniops.start

# Custom config file
mix uniops.start --config /path/to/config.exs
```

### Mix Release

`MIX_ENV=prod mix release` produces a standalone `uniops` binary.

- `rel/env.sh.eex` translates `UNIOPS_NODE` and `UNIOPS_COOKIE` into `--sname`/`--name` and `--cookie` VM flags
- `config/runtime.exs` handles all other config resolution
- Same env vars work for both dev and production

```bash
# Build
MIX_ENV=prod mix release

# Single node
./bin/uniops start

# Cluster node
UNIOPS_NODE=a UNIOPS_COOKIE=secret UNIOPS_PEERS=b@host ./bin/uniops start

# Attach to running node
./bin/uniops remote
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
lib/uniops/
  cluster/peer_connector.ex     -- auto-connect GenServer
  config_resolver.ex            -- env var > file > default resolution logic
  application.ex                -- modify: add PeerConnector, always start API
mix.exs                         -- add release config
config.example.exs              -- reference config file (not loaded by default)
```

### What Changes from Current Behavior

- `start_api` config flag removed — API always starts (controlled by whether the app is running)
- `mnesia_dir` and `blobs_dir` derived from `UNIOPS_DATA` by default (can still be set individually)
- Application startup auto-connects to peers instead of manual `Node.connect`
- `config/test.exs` still disables API and distribution for tests

---

## Plan 8: Unison Ability Library

### Goal

Provide a Unison library where programs are written against abstract abilities (`UStorage`, `UConfig`, etc.) and the Uniops handler translates operations to HTTP calls. Programs look like:

```unison
myApp : '{UStorage, UConfig, IO, Exception} ()
myApp = do
  UConfig.set "prod" "api_key" "sk-secret"
  UStorage.write "mydb" "users" "alice" "{\"role\":\"admin\"}"
  val = UStorage.read "mydb" "users" "alice"
  printLine (Optional.getOrElse "not found" val)

main : '{IO, Exception} ()
main = Uniops.main "http://localhost:4040" myApp
```

### Ability Definitions

#### UStorage

```unison
unique ability UStorage where
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

#### UConfig

```unison
unique ability UConfig where
  set : Text -> Text -> Text -> ()
  get : Text -> Text -> Optional Text
  delete : Text -> Text -> ()
  list : Text -> [Text]
```

#### UBlobs

```unison
unique ability UBlobs where
  write : Text -> Text -> Bytes -> ()
  read : Text -> Text -> Optional Bytes
  delete : Text -> Text -> ()
  list : Text -> Text -> [Text]
```

#### UScratch

```unison
unique ability UScratch where
  put : Text -> Text -> ()
  get : Text -> Optional Text
  delete : Text -> ()
```

#### ULog

```unison
unique ability ULog where
  info : Text -> ()
  error : Text -> ()
  warn : Text -> ()
  recent : Nat -> [LogEntry]

structural type LogEntry = { level : Text, message : Text, timestamp : Text, metadata : Text }
```

#### URemote

```unison
unique ability URemote where
  execute : Text -> Text
  submit : Text -> Text
```

#### UServices

```unison
unique ability UServices where
  deploy : Text -> Text -> Text
  call : Text -> Text
  list : [ServiceInfo]
  undeploy : Text -> ()

structural type ServiceInfo = { name : Text, hash : Text, node : Text }
```

### Handler Architecture

Each ability gets a handler function that pattern-matches on the ability's operations and makes HTTP calls:

```unison
UStorage.handler : Text -> Request {UStorage} a -> {Http, Threads, IO, Exception} a
UStorage.handler baseUrl = cases
  { UStorage.write db table key value -> k } ->
    _ = postJson (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/write")
          (toJson [("key", key), ("value", value)])
    handle k () with UStorage.handler baseUrl
  { UStorage.read db table key -> k } ->
    resp = getJson (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/read/" ++ key)
    val = parseOptionalValue resp
    handle k val with UStorage.handler baseUrl
  -- ... remaining operations ...
  { a } -> a
```

### Top-Level Combinator

`Uniops.main` composes all handlers:

```unison
Uniops.main : Text -> '{UStorage, UConfig, UBlobs, UScratch, ULog, URemote, UServices, IO, Exception} a -> '{IO, Exception} a
Uniops.main baseUrl program = do
  Threads.run do Http.run do
    handle
      (handle
        (handle
          (handle
            (handle
              (handle
                (handle !program
                  with UStorage.handler baseUrl)
                with UConfig.handler baseUrl)
              with UBlobs.handler baseUrl)
            with UScratch.handler baseUrl)
          with ULog.handler baseUrl)
        with URemote.handler baseUrl)
      with UServices.handler baseUrl
```

Users who only need a subset can compose handlers individually:

```unison
myMain = do
  Threads.run do Http.run do
    handle !myApp with UStorage.handler "http://localhost:4040"
```

### Shared HTTP Helpers

A helpers module provides JSON construction and HTTP plumbing used by all handlers:

```unison
Uniops.Http.postJson : Text -> Text -> {Http, Threads, IO, Exception} HttpResponse
Uniops.Http.getJson : Text -> {Http, Threads, IO, Exception} Text
Uniops.Http.deleteReq : Text -> {Http, Threads, IO, Exception} HttpResponse
Uniops.Http.toJson : [(Text, Text)] -> Text
Uniops.Http.parseOptionalValue : Text -> Optional Text
```

### File Structure

```
unison/
  Uniops/
    Storage.u           -- UStorage ability + handler
    Config.u            -- UConfig ability + handler
    Blobs.u             -- UBlobs ability + handler
    Scratch.u           -- UScratch ability + handler
    Log.u               -- ULog ability + handler
    Remote.u            -- URemote ability + handler
    Services.u          -- UServices ability + handler
    Http/Helpers.u      -- shared HTTP + JSON utilities
  Main.u                -- Uniops.main combinator
  Examples/
    BasicStorage.u      -- example: write/read/scan
    ConfigAndSecrets.u  -- example: config management
    FullApp.u           -- example: using all abilities together
```

### Testing Strategy

Each handler is testable by:
1. Starting a Uniops server (`mix uniops.start`)
2. Running the Unison program via UCM (`run main`)
3. Verifying output

Example programs in `unison/Examples/` serve as both documentation and integration tests.

For unit testing within Unison, users can write mock handlers:

```unison
mockStorage : Request {UStorage} a -> a
mockStorage = cases
  { UStorage.read _ _ _ -> k } -> handle k (Some "mock-value") with mockStorage
  { UStorage.write _ _ _ _ -> k } -> handle k () with mockStorage
  { a } -> a
```

### What This Doesn't Cover

- **Automatic UCM project setup** — users manually create their Unison project and copy/install the library. A future `mix uniops.init.unison` task could automate this.
- **Binary serialization** — values are JSON text over HTTP, not Unison's native serialization format. This is a pragmatic choice; native serialization would require understanding UCM's wire format.
- **Streaming** — no Volturno/Seq equivalent. Operations are request-response.

---

## Build Order

1. **Plan 7: Cluster Ergonomics** — improves operator experience for everything
2. **Plan 8: Unison Ability Library** — builds on the easy-to-start cluster

They share no code. Plan 8 only needs Plan 7 to be done so the README examples say `mix uniops.start` instead of the old manual process.
