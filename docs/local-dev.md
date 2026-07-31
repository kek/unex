# Running Unex locally

*A design note for a local development mode: what it must reproduce faithfully,
what it may legitimately simplify, and how to build it in slices.*

The request this note answers:

> There should be a self-contained CLI tool (perhaps implemented with Burrito)
> that enables you to run unex services locally, for development mode so to
> speak, with all the abilities that unex implements, but they could be simpler
> and have other performance characteristics maybe, but the experience should be
> very similar to deploying them to a production server running unex

Two words in that sentence carry the whole design. **"All the abilities"** sets
the scope, so the first job is to say what the abilities actually are rather
than guess. **"Very similar"** is the acceptance criterion, and it is only
meaningful if stated as concrete commands, config and output — otherwise a local
mode becomes a toy that agrees with production right up until it matters.

## 1. What Unex actually does

Enumerated from the code, not from the prose. Two lists, because "ability" means
two different things in this codebase: the seven Unison-facing effects, and the
platform capabilities underneath them.

### 1a. Unison-facing abilities (`unison/Unex/*.u`)

| Ability | Operations | Backed by |
|---|---|---|
| `Unex.Storage` | `createDatabase`, `listDatabases`, `createTable`, `write`, `read`, `delete`, `scan`, `writeCell`, `readCell`, `tx` | Mnesia disc copies |
| `Unex.Config` | `set`, `get`, `delete`, `list` | Mnesia + AES-256-GCM, scoped by environment |
| `Unex.Blobs` | `write`, `read`, `delete`, `list` | Filesystem, `<UNEX_DATA>/blobs/` |
| `Unex.Scratch` | `put`, `get`, `delete` | ETS, lost on restart |
| `Unex.Log` | `info`, `warn`, `error`, `recent` | ETS ring buffer + Elixir Logger |
| `Unex.Remote` | `execute`, `submit` | BEAM distribution (legacy path) |
| `Unex.Services` | `deploy`, `release`, `call`, `list`, `undeploy` | Registry + dispatcher |

`Unex.main` (in `unison/Main.u`) composes all seven handlers, reading only
`UNEX_URL` and `UNEX_SECRET` from the environment. That is the entire coupling
between a Unison program and a Unex deployment, and it is why programs are safe
to publish on Share.

### 1b. Platform capabilities (Elixir side)

1. **HTTP API** (`lib/unex/api/`) on Bandit, default `:4040`. Bearer-token auth
   on every route except `GET /health` and `GET /<name>` when `<name>` resolves
   to a registered service.
2. **Durable storage** (`lib/unex/storage/`) — databases as namespaces, ordered
   tables (Mnesia `ordered_set`), cells (single named values), transactions.
3. **Encrypted secrets** (`lib/unex/abilities/config.ex`) — AES-256-GCM at rest
   in Mnesia, keyed by `UNEX_CONFIG_KEY`, scoped per environment.
4. **Blob storage** (`lib/unex/abilities/blobs.ex`) — filesystem.
5. **Ephemeral cache** (`lib/unex/abilities/scratch.ex`) — ETS.
6. **Structured log** (`lib/unex/abilities/log.ex`) — ETS ring buffer.
7. **Content-addressed code caches** (`lib/unex/cluster/`) — `HashCache` (root
   `Value` bytes by SHA-256, per-term `Code` bytes by `Link.Term` text; ETS
   mirrored to `<UNEX_DATA>/hashcache/`), plus `SourceCache`, `NameCache`,
   `DepsCache` for dashboard introspection.
8. **Deploy-time extraction** (`lib/unex/runtime.ex`) — a persistent UCM
   codebase with `@unison/base`, `@unison/http`, `@kek/unex` pre-installed;
   `pull` the developer's Share project, generate a per-deploy `_extractor.u`,
   `run Unex.Extract.main` to walk the `Value`/`Code` closure, then two more UCM
   sessions to dump name→hash and `view` per-term source.
9. **Service registry** (`lib/unex/services/registry.ex`) — `name → root hash`
   plus deploy node, timestamp, project, entry point. ETS, Mnesia-persisted when
   a `mnesia_dir` is configured, with sequential peer fallback on local miss.
10. **Dispatcher pool** (`lib/unex/dispatcher.ex`, `dispatcher/pool.ex`) — N
    long-lived `ucm run.compiled dispatcher.uc` subprocesses, length-prefixed
    frames over a localhost TCP socket, lazy `GET /code/:termhash` back-fetch,
    subprocess stdout captured as the service result, NimblePool checkout.
11. **One-shot eval** (`lib/unex.ex`) — `eval/2` and `compile_and_run/2` over an
    ephemeral `Workspace`.
12. **Clustering** — `PeerConnector` (auto-connect with backoff), `SyncServer`
    (demand-driven blob resolution across nodes), registry peer fallback,
    `Services.call(name, node: peer)` RPC routing. Storage, Config, Scratch,
    Log and Blobs are explicitly **per-node** and not replicated.
13. **Legacy bytecode API** — `POST /bytecode`, `GET /bytecode/:hash`.
14. **Dashboard** (`lib/unex_dashboard/`) — opt-in Phoenix LiveView on `:4041`
    behind Basic Auth: `/services`, `/cluster`, `/hash/:id`, `/swarm`, plus
    LiveDashboard. Fed by PubSub topics `hashcache`, `services`, `cluster`; the
    core→dashboard dependency is one-way and enforced by a boundary test.
15. **Configuration** (`config/runtime.exs`) — env var → config file
    (`UNEX_CONFIG`, `~/.config/unex/config.exs`, `/etc/unex/config.exs`) →
    default, generating and printing `UNEX_SECRET` / `UNEX_CONFIG_KEY` when
    unset, and refusing to boot a production dashboard without credentials.
16. **Packaging** — `mix release` with `rel/env.sh.eex` translating `UNEX_NODE` /
    `UNEX_COOKIE` into BEAM distribution flags; a multi-stage `Dockerfile` that
    **pins one `UCM_VERSION` across the build and runtime stages**; CI pushes
    the image and calls a deploy webhook.

## 2. The problem local dev mode actually solves

Getting one Unison change in front of your eyes today looks like this:

```
mix deps.get
mix unex.compile_dispatcher              # needs UCM; ~1 min; network on first run
export UNEX_SECRET=… UNEX_CONFIG_KEY=… UNEX_PORT=… UNEX_DATA=… UNEX_PROJECT=…
iex -S mix run --no-halt
# second terminal
ucm → project.create → lib.install @unison/http → lib.install @kek/unex
load service.u → add → push                # ← round trip through Unison Share
run mainDeploy                             # ← server pulls from Share, 50–70 s
curl localhost:4040/my-service
```

`.envrc` in this repo is the honest evidence: nine exported variables that a
developer has to know about before anything works — one of which
(`UNEX_ADMIN_PASSWORD`) nothing in the codebase has ever read. It appears in no
tracked file except this sentence: `git log --all -S UNEX_ADMIN_PASSWORD` finds
only drafts of this paragraph. That is what happens to setup living in a file
nobody reviews. And the inner loop for a one-character change goes out to the
network twice and takes over a minute.

An audit of those nine (plus the commented-out `UNEX_URL`) found the reverse
problem to be the more common one: five variables the code reads that nothing
documented — `UNEX_PROJECT`, `UNEX_API_URL`, `UNEX_DISPATCHER_POOL_SIZE`,
`UNEX_DASHBOARD_URL` and the server-injected `UNEX_DISPATCHER_PORT`. They are in
the README's tables now, and `test/unex/env_documentation_test.exs` fails if a
new one appears without a row. Two more notes for anyone copying `.envrc`
around: `UNEX_DASHBOARD_PASS=secret` is on the rejected-password list in
`Unex.Dashboard.Credentials`, so that value cannot boot a production dashboard;
and `UNEX_PROJECT` is only needed for a Share-pull deploy, not for
`mix unex.deploy`.

So "development mode" is not primarily about performance. It is about **two
things**: collapsing the eight-step setup into one command, and removing the
Share round trip from the edit→see loop. Everything else in the list above
already runs perfectly well on a laptop.

## 3. Faithful vs. legitimately simpler

The whole value of a local mode is that what you see locally predicts what
happens in production. So the split is not "what is easy" — it is "what would
change the *meaning* of a passing local run".

### Must be faithful (same code, not a local equivalent)

- **The HTTP API surface, ports and auth.** Same routes, same `:4040`, same
  bearer token, same `GET /<name>` public-service rule. A dev mode that turns
  auth off teaches programs to omit a secret they will need in production.
- **Extraction and dispatch.** The root `Value` + transitive `Code` blob model,
  `HashCache` keying, and evaluation through a real `ucm run.compiled` dispatcher
  over the real socket protocol. This is where Unex is genuinely unusual; a local
  shortcut here (say, `ucm run.file` per call) would make local runs prove
  nothing about production behaviour, and would silently hide the whole class of
  "this term did not serialise" failures.
- **Hash-is-the-version semantics.** `deploy` mints a hash, `release` moves a
  pointer, old hashes stay resolvable. Rollback must behave identically.
- **Config resolution order and variable names.** `UNEX_*`, in the same
  precedence, resolved by the same `config/runtime.exs`. No parallel
  `UNEX_DEV_*` namespace.
- **Storage durability and encryption.** Mnesia on disk and AES-256-GCM, not an
  in-memory stand-in. A local mode where secrets are plaintext cannot show you
  the failure mode that actually bites (a rotated `UNEX_CONFIG_KEY` making
  existing values unreadable).

### May legitimately be simpler or slower

- **One node.** Dev mode is single-node by default; `PeerConnector`,
  `SyncServer` peer fallback and RPC routing are exercised only when you ask for
  a second node. (Slice 4.)
- **A smaller dispatcher pool.** One worker instead of four is fine locally and
  makes the log readable; it changes latency under concurrency, not semantics.
- **Deploy latency.** Local deploys can stay slow. Measured on this bench, one
  `@kek/counter` deploy took **101 s**, of which **95 s** was stages 2 and 3
  (`find`/`find-in` across 1766 named terms, the name→hash dump, and per-term
  `view`). The closure walk that actually produces the deployed bytes was about
  6 s. So the honest speed lever locally is *not* making UCM faster — it is
  skipping the Share round trip and skipping source capture.
- **Source capture for the dashboard.** Stages 2 and 3 of `Runtime.extract`
  (name→hash dump, per-term `view`) exist to make `/hash/:id` pretty, and they
  are 94% of deploy time (above). Skipping them locally is the single biggest
  legitimate speed knob, because nothing about program behaviour depends on
  them — the deployed `Value` and `Code` bytes are identical either way.

  Slice 2 took that knob and set it by ingestion mode: **off for `{:file, _}`,
  on for `{:share, _}`.** Both defaults are overridable (`--capture-source` /
  `--no-capture-source`, or `"capture_source"` in the deploy body), and the entry
  point's own source is captured on both paths regardless because it comes free
  in the same UCM session as the closure walk — so `/hash/<root>` still shows the
  program you deployed, just not every term underneath it.

  The two levers turn out to be separable, and worth separating. Measured on this
  bench, same `mainCounter`, one deploy each:

  | | stage 1 (ingest + walk) | stages 2–3 | total |
  |---|---|---|---|
  | `{:share, "@kek/counter"}`, capture on | 13.2 s | 60.1 s | **73.9 s** |
  | `{:file, "counter.u"}`, capture on | 4.4 s | 50.9 s | **56.3 s** |
  | `{:file, "counter.u"}`, capture off | 4.7 s | — | **5.1 s** |

  So killing the Share round trip is worth about 9 seconds and skipping source
  capture is worth about 51 — together, 14× on the inner loop. Doing only the
  first would have been a hollow win, which is why this slice did both. And the
  claim that skipping it changes nothing about the deployed bytes is not an
  argument in this document: it is an assertion in
  `test/integration/deploy_local_file_test.exs`, which extracts the same file
  with capture off and on and compares the root value and every `Code` blob.
- **The dashboard itself.** Off unless asked for.
- **Credential generation.** Dev mode may pin a stable secret so restarts do not
  invalidate encrypted values — that is *more* durable than production default
  behaviour, not less faithful.

## 4. Where divergence will actually come from

Four of these are real and one is already a live bug.

**(a) UCM version skew — the big one, and it is not hypothetical.** A compiled
`.uc` bundle records the exact UCM that built it, and UCM refuses to run a
mismatched one. On this bench:

```
$ ucm version
unison version: release/1.3.0 (built on 2026-05-13)

$ ucm run.compiled ~/.local/share/unex/dispatcher.uc
  I can't run this compiled program since it works with a different version of
  Unison than the one you're running.

  Compiled file version
      release/1.2.0 (built on 2026-04-14)

  Your version
      release/1.3.0 (built on 2026-05-13)
```

`Dockerfile` pins `UCM_VERSION=1.2.0`. So production and this laptop cannot
share a dispatcher bundle at all, and there is no reason to expect a developer's
UCM to match the image's. Consequences for the design:

- Dev mode must **build the dispatcher against the local UCM** and must
  **report the version it used**, prominently. Hiding the version is how "works
  in dev" gets manufactured.
- The current failure mode is bad: a stale bundle makes `Unex.Dispatcher.init`
  spawn UCM, wait `@accept_timeout` (10 s), log `accept timed out`, and die —
  four times over in a pool of four — after which every service call returns
  `{:error, :dispatcher_not_started}`. Detecting the mismatch *before* boot is
  cheap: the `.uc` header is a big-endian 32-bit length followed by the version
  text. This is slice 1's sharp edge.
- Whether serialized `Code` blobs in `HashCache` survive a UCM upgrade is a
  separate, unanswered question. Until it is answered, a dev `HashCache` should
  be treated as disposable and never presented as interchangeable with
  production's.

**(b) The code-ingestion step.** Local deploys must not go through Share. The
tempting shortcut — a separate local compile path — is exactly the trap: it
would produce `Value`/`Code` bytes by different machinery than production and
drift silently. The right shape is to replace *only* the `pull <project>` line
inside `Runtime.extract` with `load <file>` + `update` against the same
persistent codebase, keeping the generated extractor, the closure walk, the
`##builtin` skipping and the `HashCache` keying byte-identical. One parameter,
not one new path.

Residual risk that remains even then: names resolve against a codebase you
`load`ed rather than one you `pull`ed, so a program can work locally and fail on
deploy because the Share project's `lib` versions differ. Dev mode should say
which project/codebase it resolved against, and the local flow must stay a
*superset*: `deploy --from-share` has to keep working unchanged.

**(c) `:data_dir` is never set from `UNEX_DATA`.** `config/runtime.exs` derives
`mnesia_dir`, `blobs_dir` and `hash_cache_dir` from `UNEX_DATA`, but never sets
`:data_dir` itself — while `Unex.Runtime` and `Unex.Dispatcher` both read
`Application.get_env(:unex, :data_dir, "data")`. So with `.envrc`'s
`UNEX_DATA=$HOME/.local/share/unex`, Mnesia, blobs and the hash cache go to
`~/.local/share/unex`, and the **runtime codebase and dispatcher bundle go to
`./data` relative to the current working directory**. Production gets away with
it only because Docker's `WORKDIR=/app` and `UNEX_DATA=/app/data` happen to
agree, and `UNEX_DISPATCHER` is set explicitly. Any tool that runs Unex from a
different directory hits it immediately. Fixed in slice 1 by setting `data_dir`
in `runtime.exs`, which is a one-line correction to the real config path rather
than a dev-only workaround.

**(d) Single node hides per-node state.** Storage, Config, Scratch, Log and Blobs
are not replicated. A counter incremented on A and on B is two counters. A
single-node dev mode cannot surface that class of bug, so the docs must say so
and slice 4 must make a second node one flag away.

**(e) A second config resolver already exists.** `Unex.ConfigResolver` is a full
env→file→default resolver with 20-odd tests — and nothing in the boot path calls
it; `config/runtime.exs` re-implements the same logic inline and has since
grown `api_url`, `dispatcher_path`, pool size and all the dashboard variables
that `ConfigResolver` knows nothing about. It is a worked example of precisely
the drift this note is trying to avoid, and a dev tool must not become the third
copy. Dev mode therefore configures the node by **setting environment variables
and letting `config/runtime.exs` resolve them**, then reading the resolved
values back out of the application environment.

## 5. What "very similar" means, concretely

The test of this design is whether the following table holds, because these are
the things a developer's fingers and eyes actually touch.

| | Production | Local dev mode |
|---|---|---|
| Start | `bin/unex start` | `mix unex.dev` |
| Config | `UNEX_PORT`, `UNEX_DATA`, `UNEX_SECRET`, `UNEX_CONFIG_KEY`, `UNEX_DASHBOARD*`, … | the same names, same precedence, resolved by the same `config/runtime.exs` |
| Health | `curl $HOST/health` → `{"status":"ok"}` | `curl localhost:4040/health` → `{"status":"ok"}` |
| Auth | `Authorization: Bearer $UNEX_SECRET` | identical, secret printed at boot and stable across restarts |
| Deploy | Unison `Unex.Services.deploy`, server pulls from Share | `mix unex.deploy ./service.u mainService --as my-service`, and the Unison path still works |
| Call | `curl $HOST/my-service` | `curl localhost:4040/my-service` |
| Result | raw stdout as `text/html` | byte-identical |
| Version | root hash | same hash for the same code |
| Rollback | `release name <old-hash>` | identical |
| Dashboard | `:4041`, Basic Auth | `:4041`, Basic Auth |
| Logs | Elixir Logger | identical, foreground |

Where it deliberately differs, it must *say so out loud at boot*: UCM version,
data directory, dispatcher bundle path and the version it was built with, pool
size, whether the dashboard is on, and that this is a single node.

## 6. Packaging: Burrito, or something smaller?

Karl said "perhaps Burrito". Evaluated, and the recommendation is **no, not for
this** — but for a reason that is worth stating precisely, because it is not
"Burrito is bad".

Burrito wraps a Mix release into a self-extracting binary with ERTS inside,
cross-compiling via Zig. It needs `zig` (pinned at 0.15.2), `xz`, and `7z` for
Windows targets. On this bench `zig 0.15.2` and `xz` are both present, so
feasibility is not the objection.

The objection is that **the binary cannot be self-contained anyway**. Unex's
execution path is UCM: `Unex.Runtime` spawns `ucm` to extract, and every
`Unex.Dispatcher` worker *is* a `ucm run.compiled` subprocess. On top of that,
`dispatcher.uc` has to be built by the *same* UCM version that will run it
(§4a). So a Burrito binary still requires the user to install UCM, at a version
that matches a bundle the binary cannot have pre-built for them. Burrito would
bundle the one prerequisite that was never the problem (ERTS) and leave the one
that is (UCM). "Self-contained" is blocked by Unison's toolchain, not by Elixir's.

The second objection is the dev loop. Burrito's output is a production release
artifact. A tool used *while developing Unex itself* would need rebuilding on
every change, whereas the repo already ships `code_reloader: true` and `exsync`
in `config/dev.exs` for exactly this.

Alternatives weighed:

- **Mix task (recommended).** `mix unex.dev`, `mix unex.deploy`. Zero new
  dependencies, works offline, no build step, and — the decisive property — it
  boots by rerunning `app.config` and `app.start`, so `config/runtime.exs` and
  `Unex.Application` are *the same code paths a release boots through*. This
  matches how `mix unex.compile_dispatcher` and `mix docs.pdf` already work in
  this repo. It requires a repo checkout, which is true of everyone who is
  developing Unison services against Unex today.
- **escript.** One copyable file, but it does not bundle ERTS (still needs
  Erlang), cannot carry the `unison/` sources or `dispatcher.uc`, and is awkward
  with `mnesia`/`os_mon` applications. It gives up the "same boot path" property
  and buys almost nothing.
- **`mix release` + `bin/unex dev`.** If Karl later wants a copyable artifact for
  someone without the repo, this is the honest one: `mix.exs` already declares a
  `unex` release with `rel/env.sh.eex`, so a `dev` command in the release script
  is nearly free and is *literally* the production entry point. Reach for
  Burrito only if a bundled ERTS turns out to be the remaining obstacle for a
  real second user — and only once UCM installation is solved, since that
  dominates.

Recommendation: **build the CLI as Mix tasks now; revisit release-based
packaging (not Burrito) if and when a user without a repo checkout appears.**

## 7. Slicing plan

Each slice is independently useful and independently validated.

**Slice 1 — `mix unex.dev`: one command, a correct node.** *(delivered)*
Preflight UCM and report its version; resolve a dev data directory and set
`data_dir` so the runtime codebase, dispatcher bundle and Mnesia stop
disagreeing; persist the generated `UNEX_SECRET` / `UNEX_CONFIG_KEY` so restarts
keep encrypted Config readable; **read the dispatcher bundle's embedded UCM
version and rebuild it (via the existing `mix unex.compile_dispatcher`) when it
is missing or stale**, instead of discovering it as four 10-second accept
timeouts; boot the real `Unex.Application` through the real config pipeline;
print a banner that states every divergence and gives copy-pasteable `export`
and `curl` lines. Validated by: unit tests over the bundle header parse, the
version comparison and the credential file; and a real boot with `/health` and
`/services` answering.

**Slice 2 — `mix unex.deploy <file.u> <entry> --as <name>`: kill the Share round
trip.** *(delivered)* Parameterise `Runtime.extract` on how source enters the
codebase — `{:share, project}` (today, unchanged) or `{:file, path}` (`load` +
`update`) — leaving the extractor, closure walk and `HashCache` keying untouched.
Same `POST /services/:name/deploy` endpoint with a new body field, so the Unison
`Unex.Services.deploy` ability and the HTTP API stay as they are. Validated by:
deploying a local `.u`, calling `GET /<name>`, and asserting the root hash equals
the hash the Share path produces for the same code.

As built, the one parameter is `Unex.Runtime.ingest_commands/1` — two clauses,
`pull <project>` and `load <path>` + `update` — with `extract_commands/3`
building the rest of the UCM session around it. A unit test asserts the two
command scripts are identical apart from that prefix; that is the cheap
structural guard. The expensive one is the hash equality above, and it holds:
`@kek/counter`'s `mainCounter` from Share and the same code transcribed into a
local `.u` produce the same root hash and the same 522 `Code` blobs, byte for
byte, extracted against two separate codebases where the file half's codebase
had never seen the Share project.

The new body field is `"source"`, carrying the file's *text* rather than a path,
so the endpoint does not assume the client shares a filesystem with the server
and an API token does not become "read any file on the box". The server writes it
to a temporary `.u`, because UCM ingests source through `load <path>`.

Two consequences worth knowing. A file deploy records `project: nil` in the
service registry, because `project` is a `ucm pull` argument and a file has no
such thing — so the dashboard shows no source link for it, and deploying a file
over a name previously deployed from Share *clears* the old link rather than
leaving it pointing at code that is no longer running. And the residual risk §4b
names is real and unmitigated: names in a `load`ed file resolve against whatever
`lib` versions this codebase happens to have, so a program can hash locally to
something Share would not reproduce if those versions differ. The equivalence
test is what catches that, and it catches it as an inequality of hashes rather
than as a mystery in production.

**Slice 3 — `mix unex.watch`: the actual inner loop.** Watch a `.u` file,
re-deploy on save, print the new hash and the time taken. Slice 2 makes this
trivial and it is where the "very similar, but fast" experience finally lands.
Validated by: edit a file, observe a new hash and changed output without
restarting the node.

**Slice 4 — `mix unex.dev --peer`: a second node on one machine.** Boot a second
node with distribution and `UNEX_PEERS` wired up, so `SyncServer` fallback,
registry peer lookup and the per-node-storage surprise are all reachable
locally. Validated by: deploy on A, call on B, assert the blob arrives via
`SyncServer` and that a counter on A and B genuinely diverge.

**Slice 5 — packaging, only if wanted.** `bin/unex dev` in the release, and a
documented UCM install step. Not Burrito unless §6's reasoning changes.

**Deliberately out of scope**: a mock/in-memory backend for the abilities. Unison
already has the better answer — swap the ability handler, as `docs/guide.md`
Part 7 shows. Reimplementing the storage layer in Elixir "for tests" would be a
second implementation of the thing this whole note is trying to protect.
