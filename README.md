*Note: this repository is an experimental investigation for myself to learn about Unison, operations and AI engineering. It's not intended to be productified or to compete with Unison Cloud. The basic example does work as a kind of proof of concept, but the system isn't feature complete or secure for running any type of workload. For proper deployment of Unison services, please use Unison Cloud! Everything except this paragraph is written by coding agents.*

# the unix hater's revenge

An open-source ops platform for [Unison](https://www.unison-lang.org/) programs. Durable storage, encrypted secrets, clustering, and content-addressed code execution — all on the BEAM.

## Quick start

```bash
# Prerequisites: Elixir 1.19+, UCM (Unison Codebase Manager) 1.2.0
mix deps.get
mix unex.compile_dispatcher   # one-time, produces data/dispatcher.uc
iex -S mix run --no-halt      # or: mix run --no-halt
```

The API starts on `http://localhost:4040`. A secret is auto-generated on first run (printed to stdout). Set `UNEX_SECRET` to persist it across restarts.

```bash
curl -s localhost:4040/health
# {"status":"ok"}
```

## Local development mode

The quick start above works, but it leaves you to remember eight environment
variables and to notice for yourself when `dispatcher.uc` was built by a
different UCM than the one on your PATH. `mix unex.dev` does that part:

```bash
mix unex.dev                 # one node, API on :4040
mix unex.dev --dashboard     # plus the dashboard on :4041
mix unex.dev --check         # run every preflight, print the banner, don't boot
```

It sets the ordinary `UNEX_*` variables and lets `config/runtime.exs` resolve
them exactly as a release boot does — it is the same code path, not a
simplified copy. What it adds is local-development care: it rebuilds the
dispatcher bundle when the local UCM cannot run it, keeps the generated
`UNEX_SECRET` and `UNEX_CONFIG_KEY` in `<data-dir>/dev.env` so encrypted
`Unex.Config` values survive a restart, and prints every way the node differs
from a production one.

State lives in `~/.local/share/unex/dev` by default; `--data PATH` moves all of
it at once.

Deploying still goes through Unison Share today. Removing that round trip from
the edit-and-see loop is the next slice — see **[docs/local-dev.md](docs/local-dev.md)**
for the design, the enumerated abilities a local mode has to reproduce, and why
this is a Mix task rather than a Burrito binary.

## Dashboard

The dashboard is an opt-in Phoenix LiveView subsystem that runs in the same
BEAM node as the Unex core and exposes real-time views of cluster state, hash
cache distribution, service lifecycle, and runtime metrics.

Enable it with:

    UNEX_DASHBOARD=1 iex -S mix run --no-halt

It listens on port `:4041` by default and is protected by HTTP Basic Auth.
Open `http://localhost:4041` in a browser. In dev and test the credentials
default to `admin` / `unex`.

**In production there is no default.** A release built with `MIX_ENV=prod` that
enables the dashboard must also set `UNEX_DASHBOARD_USER` and
`UNEX_DASHBOARD_PASS`, or it refuses to boot — an ops dashboard behind a
password published in this README is not worth serving. Setting
`UNEX_DASHBOARD_SECRET` (session cookie signing key) is optional; without it a
random one is generated per boot, which only costs open dashboard sessions on
restart.

    UNEX_DASHBOARD=1 \
      UNEX_DASHBOARD_USER=ops \
      UNEX_DASHBOARD_PASS="$(openssl rand -base64 24)" \
      bin/unex start

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
| `UNEX_DASHBOARD_HOST` | `127.0.0.1` | Dashboard bind address; set to `0.0.0.0` to expose on all interfaces |
| `UNEX_DASHBOARD_USER` | `admin` in dev/test, **required in prod** | Basic Auth username for the dashboard |
| `UNEX_DASHBOARD_PASS` | `unex` in dev/test, **required in prod** | Basic Auth password for the dashboard |
| `UNEX_DASHBOARD_SECRET` | *(generated)* | Signing key for dashboard session cookies |

Config file: `~/.config/unex/config.exs`, `/etc/unex/config.exs`, or `UNEX_CONFIG`. See `config.example.exs` for a full reference.

## Tests

```bash
mix test
mix test --trace
```
