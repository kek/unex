# the unix hater's revenge

An open-source ops platform for [Unison](https://www.unison-lang.org/) programs. Durable storage, encrypted secrets, clustering, and content-addressed code execution — all on the BEAM.

## Quick start

```bash
# Prerequisites: Elixir 1.17+, UCM (Unison Codebase Manager) 1.2.0
mix deps.get
mix unex.compile_dispatcher   # one-time, produces data/dispatcher.uc
mix unex.start
```

The API starts on `http://localhost:4040`. A secret is auto-generated on first run (printed to stdout). Set `UNEX_SECRET` to persist it across restarts.

```bash
curl -s localhost:4040/health
# {"status":"ok"}
```

## Dashboard

The dashboard is an opt-in Phoenix LiveView subsystem that runs in the same
BEAM node as the Unex core and exposes real-time views of cluster state, hash
cache distribution, service lifecycle, and runtime metrics.

Enable it with:

    UNEX_DASHBOARD=1 UNEX_DASHBOARD_USER=admin UNEX_DASHBOARD_PASS=secret mix unex.start

It listens on port `:4041` by default and is protected by HTTP Basic Auth.
Open `http://localhost:4041` in a browser.

Routes:
- `/` — landing page
- `/services` — deployed service list + live activity log
- `/cluster` — connected node graph
- `/hash/:id` — blob inspector
- `/swarm` — in-flight service calls across nodes
- `/dashboard` — Phoenix LiveDashboard (VM, Bandit, Mnesia)

## Using from Unison

Install the library and point it at your server:

```
myProject/main> lib.install @unison/http
myProject/main> lib.install @kek/unex
```

```bash
export UNEX_URL=http://localhost:4040
export UNEX_SECRET=<secret-printed-at-startup>
```

Write your app using abilities — no credentials in code:

```unison
myApp : '{Unex.Storage, IO, Exception} ()
myApp = do
  Unex.Storage.createDatabase "mydb"
  Unex.Storage.createTable "mydb" "users"
  Unex.Storage.write "mydb" "users" "alice" "role=admin"
  match Unex.Storage.read "mydb" "users" "alice" with
    Some val -> printLine ("Got: " ++ val)
    None     -> printLine "Not found"

main : '{IO, Exception} ()
main = Unex.main myApp
```

```
myapp/main> run main

  Got: role=admin
```

For the full tutorial — abilities, secrets, services, clustering, mock testing: **[docs/guide.md](docs/guide.md)**

## HTTP API

Curl reference for every endpoint: **[docs/api.md](docs/api.md)**

## Configuration

**Client (Unison programs):**

| Variable | Default | Description |
|----------|---------|-------------|
| `UNEX_URL` | `http://localhost:4040` | Server URL read by `Unex.main` |
| `UNEX_SECRET` | *(empty)* | Bearer token read by `Unex.main` |

**Server:**

| Variable | Default | Description |
|----------|---------|-------------|
| `UNEX_NODE` | *(none)* | Node name (`a` for local, `a@10.0.1.5` for cross-network) |
| `UNEX_COOKIE` | *(none)* | Cluster auth cookie (required with `UNEX_NODE`) |
| `UNEX_PORT` | `4040` | HTTP API port |
| `UNEX_DATA` | `./data` | Base directory for Mnesia and blob storage |
| `UNEX_PEERS` | *(none)* | Comma-separated peer nodes to auto-connect |
| `UNEX_SECRET` | *(generated)* | Bearer token for API authentication |
| `UNEX_CONFIG_KEY` | *(generated)* | AES-256-GCM encryption key for Config secrets |
| `UNEX_CONFIG` | *(none)* | Path to config file |
| `UCM_PATH` | `ucm` | Path to UCM binary |
| `UNEX_DISPATCHER` | `<UNEX_DATA>/dispatcher.uc` | Path to the compiled dispatcher bundle (used by the long-lived dispatcher process that evaluates service calls) |
| `UNEX_DASHBOARD` | *(off)* | Set to `1`/`true`/`yes` to enable the Phoenix LiveView dashboard |
| `UNEX_DASHBOARD_PORT` | `4041` | Dashboard HTTP port |
| `UNEX_DASHBOARD_USER` | `admin` | Basic Auth username for the dashboard |
| `UNEX_DASHBOARD_PASS` | `unex` | Basic Auth password for the dashboard |

Config file: `~/.config/unex/config.exs`, `/etc/unex/config.exs`, or `UNEX_CONFIG`. See `config.example.exs` for a full reference.

## Tests

```bash
mix test
mix test --trace
```
