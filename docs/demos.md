# Unex Demo Scripts

Six wow-factor demos for showing what Unex can do, each written as a stage script
with on-screen actions and speaker notes. Each demo is independently runnable;
a few pair well (see "Suggested sequences" at the bottom).

Conventions used in the scripts:

- **[SCREEN]** — what the audience sees (terminal, browser, slide).
- **[DO]** — what the presenter types or clicks.
- **[SAY]** — what the presenter says.
- **[BEAT]** — a deliberate pause for the point to land.

All demos assume these env vars are set in every shell:

```
UNEX_URL=http://localhost:4040
UNEX_SECRET=<your secret>
UNEX_PROJECT=<your Unison project name, e.g. @you/demos>
```

---

## Demo 1 — The Self-Propagating Service

**Length:** ~5 minutes
**Sells:** content-addressed code distribution; "redeploy is kilobytes".
**Requires:** three Unex nodes clustered (`UNEX_PEERS`), one Unison Share
project pushed.

### Setup (before the audience arrives)

1. Pick a shared dispatcher path and build it once. The cluster nodes
   each use a per-node `UNEX_DATA`, so the dispatcher binary needs to
   live somewhere all three can read. Both the compile task and the
   runtime read `UNEX_DISPATCHER`, so set it once and reuse it:
   ```
   export UNEX_DISPATCHER=$PWD/dispatcher.uc
   mix unex.compile_dispatcher
   ```
   Confirm the file exists at `$UNEX_DISPATCHER` before continuing.

2. With `UNEX_DISPATCHER` exported in your shell from step 1, start
   three nodes on the same machine with different data dirs. `UNEX_PORT`
   is the API port; the dashboard (if enabled) defaults to `4041`, so
   don't reuse `4041` as another node's API port — pick API ports with
   a gap and assign each dashboard its own port. Use long-name BEAM
   nodes (`a@localhost`, not bare `a`) so peer addresses match what the
   runtime actually registers:
   ```
   UNEX_NODE=a@localhost UNEX_PORT=4040 UNEX_DASHBOARD=1 UNEX_DASHBOARD_PORT=5040 \
     UNEX_DATA=./data/a UNEX_COOKIE=demo mix unex.start

   UNEX_NODE=b@localhost UNEX_PORT=4050 UNEX_DASHBOARD=1 UNEX_DASHBOARD_PORT=5050 \
     UNEX_DATA=./data/b UNEX_COOKIE=demo UNEX_PEERS=a@localhost mix unex.start

   UNEX_NODE=c@localhost UNEX_PORT=4060 UNEX_DASHBOARD=1 UNEX_DASHBOARD_PORT=5060 \
     UNEX_DATA=./data/c UNEX_COOKIE=demo UNEX_PEERS=a@localhost mix unex.start
   ```
   The dashboard is opt-in. If you only want it on node A, drop
   `UNEX_DASHBOARD=1` (and `UNEX_DASHBOARD_PORT`) from B and C.
3. Have a UCM window open on your Unison project with a small service ready to
   push — a greeter function is enough:
   ```
   greeter : '{Unex.Storage, IO, Exception} ()
   greeter = do printLine "Hello from v1"

   mainGreeter = Unex.main greeter
   mainDeploy   = Unex.main do
     hash = Unex.Services.deploy "greeter" "mainGreeter"
     Unex.Services.release "greeter" hash
     printLine ("Deployed greeter: " ++ hash)
   ```

### Script

1. **[SCREEN]** Slide: "One hash, three nodes."
   **[SAY]** "Most platforms ship code as a container. I'm going to ship code as
   a hash, and I'm going to show you that the three nodes in this cluster only
   fetch the hashes they don't already have."

2. **[SCREEN]** UCM window on node A.
   **[DO]** `push`, then `run mainDeploy`.
   **[SCREEN]** Output shows `Deployed greeter: #abc…`.
   **[SAY]** "I deployed `greeter` on node A. The server pulled my project,
   extracted the entry point, and stored the root `Value` plus every `Code` blob
   it reaches in the hash cache."

3. **[SCREEN]** Terminal tailing node C's log.
   **[DO]** `curl -H "Authorization: Bearer $UNEX_SECRET" -X POST $UNEX_URL_C/services/greeter/call`
   (where `$UNEX_URL_C` is node C on port 4042).
   **[SCREEN]** Logs show C issuing `GET /code/<termhash>` calls back to A for
   each missing blob, then caching them.
   **[SAY]** "C didn't have the code. It resolved each hash through the
   SyncServer, cached it in its own HashCache, and then ran the dispatcher
   against that cached bytecode."

4. **[DO]** Hit node C again.
   **[SCREEN]** Logs show zero `GET /code` requests.
   **[SAY]** "Second call, no fetches. The cache is warm. Every node in the
   cluster ends up with the blobs it actually needs, lazily."
   **[BEAT]**

5. **[SCREEN]** UCM.
   **[DO]** Change `"Hello from v1"` to `"Hello from v2"`, `add`, `push`,
   `run mainDeploy`.
   **[SCREEN]** New hash printed.
   **[DO]** Hit C again, show logs.
   **[SAY]** "Only the new hashes transferred. Everything else — the `printLine`
   impl, the ability machinery, the IO wiring — was already there. Redeploy is
   kilobytes, not megabytes."

6. **[SCREEN]** Slide: "Code is the artifact. The hash is the version."
   **[SAY]** "This is git-for-running-code. Rolling back is re-pointing a name
   at an old hash — the blob never left."

---

## Demo 2 — Function-as-a-URL in 30 Seconds

**Length:** ~3 minutes
**Sells:** zero-config deploy; Unison function to live HTTPS endpoint.
**Requires:** one Unex node, one Unison Share project, a browser.

### Setup

- Node running on `:4040`.
- UCM open, project ready to `push`.
- Browser window showing `http://localhost:4040/counter` (currently 404).

### Script

1. **[SCREEN]** Browser showing 404. Slide overlay: "From prompt to production
   URL in under a minute."
   **[SAY]** "There's nothing at this URL yet. I'm going to make it a real web
   page with a Unison function."

2. **[SCREEN]** UCM.
   **[DO]** Type (or paste) this, live:
   ```
   counter : '{Unex.Storage, IO, Exception} ()
   counter = do
     Unex.Storage.createDatabase "counter"
     current = match Unex.Storage.readCell "counter" "hits" with
       Some n -> Optional.getOrElse 0 (Nat.fromText n)
       None   -> 0
     new = current + 1
     Unex.Storage.writeCell "counter" "hits" (Nat.toText new)
     printLine (counter.html new)

   counter.html : Nat -> Text
   counter.html n =
     use Text ++
     "<!DOCTYPE html><body style='font-family:system-ui;text-align:center;padding:4em'>"
       ++ "<h1>Visitor #" ++ Nat.toText n ++ "</h1>"
       ++ "<p>Powered by Unex.</p></body>"

   mainCounter = Unex.main counter

   mainDeploy = Unex.main do
     hash = Unex.Services.deploy "counter" "mainCounter"
     Unex.Services.release "counter" hash
     printLine ("Deployed: " ++ hash)
   ```
   **[SAY]** "Storage ability for durable state, Unex.main to wire up the
   HTTP-backed handlers, a function that emits HTML on stdout. That's the whole
   service."

3. **[DO]** `add` → `push` → `run mainDeploy`.
   **[SAY]** "`push` to Share so the server can fetch it, deploy names the
   service, release points traffic at this hash."

4. **[SCREEN]** Flip to browser, refresh.
   **[SCREEN]** "Visitor #1".
   **[SCREEN]** Refresh again → "Visitor #2", again → "Visitor #3".
   **[SAY]** "That's a Unison function at a live URL with persistent storage.
   No Dockerfile, no build pipeline, no ingress config, no database migration.
   Faster than `vercel deploy`."
   **[BEAT]**

5. **[SCREEN]** Slide: "The deploy artifact is the function."
   **[SAY]** "If you have three nodes clustered, `/counter` works on all
   three. Same hash, same storage, same counter."

---

## Demo 3 — Cross-Service Composition, No RPC Plumbing

**Length:** ~6 minutes
**Sells:** microservices as function composition; zero schema boilerplate.
**Requires:** one or two nodes. Two nodes is more convincing.

### Setup

Have three tiny services ready to paste or load from a file:

- **users** — `Unex.Storage` lookup by id.
- **render** — formats a user record into HTML, calls `users` via
  `Unex.Services.call`.
- **auth** — checks a bearer against `Unex.Config`, wraps `render`.

### Script

1. **[SCREEN]** Slide: "Three services. One call chain. Zero protobuf."
   **[SAY]** "Most microservice demos involve thirty minutes of YAML before a
   single request goes through. I'm going to wire three services together in
   Unison and the only interface is the function signature."

2. **[DO]** Deploy `users` first.
   ```
   users : '{Unex.Storage, IO, Exception} ()
   users = do
     Unex.Storage.createDatabase "users"
     Unex.Storage.writeCell "users" "1" "Alice"
     Unex.Storage.writeCell "users" "2" "Bob"
     -- read the id from the Scratch cache (set by caller)
     match Unex.Scratch.get "userId" with
       Some id -> match Unex.Storage.readCell "users" id with
         Some name -> printLine name
         None      -> printLine "unknown"
       None -> printLine "no id"
   ```
   **[SAY]** "Plain Unison. Storage ability for persistence, Scratch ability
   for per-call input. Deployed."

3. **[DO]** Deploy `render`:
   ```
   render = do
     Unex.Scratch.put "userId" "1"
     name = Unex.Services.call "users"
     printLine ("<h1>Hello, " ++ name ++ "</h1>")
   ```
   **[SAY]** "`render` calls `users` by name. The platform routes it through
   the dispatcher. No stub generation, no client library, no OpenAPI."

4. **[DO]** Deploy `auth` that wraps `render`.
   **[DO]** `curl /auth` — get rendered HTML.
   **[SAY]** "Three hops across three services. Everything composed by calling
   functions."

5. **[SCREEN]** Second terminal: `kill` the BEAM node that owns one of them.
   **[DO]** Curl again.
   **[SCREEN]** Request still succeeds from the surviving node.
   **[SAY]** "Because services are identified by a hash and every node has the
   blobs it needs, the supervisor on the surviving node just runs it. No
   consul, no sidecar, no control plane."

6. **[SCREEN]** Slide: "Microservices are just functions. The platform is the
   glue."

---

## Demo 4 — Time-Travel Debugging by Hash

**Length:** ~5 minutes
**Sells:** every version of every service is permanently addressable.
**Requires:** one node; a service that's been deployed twice with different
behavior.

### Setup

- Deploy `pricer` v1 (say: `price = 10`).
- Keep the hash from `mainDeploy`'s output.
- Change to v2 (`price = 15`), deploy again, keep that hash.
- Note: `Unex.Services.release NAME HASH` selects which hash a name points at.

### Script

1. **[SCREEN]** Slide: "Every deploy is a hash. Every hash is still there."
   **[SAY]** "In most systems, yesterday's code is gone unless you rebuilt a
   container. Here, every version I've ever deployed is still in the hash
   cache — addressable forever."

2. **[DO]** `curl /services/pricer/call` → `10`.
   **[SAY]** "Current version returns 10."

3. **[DO]** Rollback by re-releasing v1's hash:
   ```
   curl -H "Authorization: Bearer $UNEX_SECRET" \
        -X POST $UNEX_URL/services/pricer/release \
        -d '{"hash":"#<v1-hash>"}'
   ```
   **[DO]** Call again → `10` (if v1 was 10) or `15` depending on which was
   which — whichever hash you re-released.
   **[SAY]** "Rollback is a hash change. The old bytecode didn't move; it was
   already there."

4. **[DO]** Flip back to the other hash. Call again.
   **[SAY]** "Forward again. Same operation. No build, no deploy."

5. **[SCREEN]** Slide: "Provenance is free when the version *is* the content."
   **[SAY]** "If you log the hash alongside every response, you can replay the
   exact code that produced any historical result, forever, as long as the
   blobs are in the cache."

---

## Demo 5 — Distributed Agent Swarm

**Length:** ~7 minutes
**Sells:** clustering + Remote + Config/Blobs/Scratch composed into real work.
**Requires:** 3 nodes clustered; an LLM API key stored in `Unex.Config`;
something to fan out (100 prompts, 100 URLs, 100 files).

### Setup

1. Store the key once:
   ```
   curl -H "Authorization: Bearer $UNEX_SECRET" \
        -X POST $UNEX_URL/config/prod \
        -d '{"key":"openai_key","value":"sk-..."}'
   ```
2. Deploy an `agent` service that reads one task id from `Scratch`, pulls the
   prompt from storage, calls the LLM, writes the artifact to `Blobs`, logs via
   `Unex.Log`.
3. Deploy a `fanout` service that does the spreading.

### Script

1. **[SCREEN]** Slide: "A distributed agent runtime in 40 lines."
   **[SAY]** "I'm going to fan 100 tasks across three nodes. Each agent reads
   config, calls an LLM, writes a file, and logs. No Airflow, no Celery, no
   Kafka."

2. **[SCREEN]** Show `agent.u` on screen — highlight the abilities row:
   `'{Unex.Config, Unex.Blobs, Unex.Log, Unex.Scratch, IO, Exception}`.
   **[SAY]** "One function. The abilities tell you exactly what it needs: a
   config (the API key), a blob store (the output), a log, a scratch pad for
   the task id. Nothing else."

3. **[SCREEN]** A monitoring terminal tailing logs from all three nodes, side
   by side.
   **[DO]** Trigger the fanout: `curl -X POST /services/fanout/call`.
   **[SCREEN]** Agents log across all three nodes in parallel.
   **[SAY]** "The BEAM scheduler is spreading work. `Unex.Remote` / `rpc.call`
   dispatches each task to whichever node is least loaded."

4. **[DO]** `ls data-*/blobs/` on each node.
   **[SCREEN]** Output files present, distributed across nodes.
   **[SAY]** "Artifacts wrote locally on whichever node ran them. If I need
   them globally, Blobs replicates through the same hash-cache machinery the
   services use."

5. **[SCREEN]** Slide: "The primitives composed — Config, Blobs, Log, Scratch,
   Services — are the agent framework."

---

## Demo 6 — Live Schema Migration, Zero Downtime

**Length:** ~6 minutes
**Sells:** canary deploy + schema migration using only platform primitives.
**Requires:** 2 nodes; a service `orders` with an old record shape.

### Setup

- Pre-populate `orders` with a few rows in v1 shape: `amount=10`.
- Have v2 ready: reads v1, migrates on read to `{amount: 10, currency: "USD"}`,
  writes v2 shape back.
- Have a config flag `orders_version` in `Unex.Config`.

### Script

1. **[SCREEN]** Slide: "Migration without a maintenance window."
   **[SAY]** "We're going to deploy a new schema, run both versions at once,
   shift traffic, and roll back — using only Storage, Config, and Services."

2. **[DO]** Call `orders` a few times, show v1 responses.

3. **[DO]** Deploy v2 under a second name `orders_v2`.
   **[SAY]** "v2 is a whole separate service. It reads the same table, treats
   missing fields as defaults, and writes v2 shape on any touched row."

4. **[DO]** Flip a small percentage of reads to `orders_v2` via a router
   service that checks `Unex.Config.get "env" "orders_version"`.
   **[SCREEN]** Mix of v1 and v2 responses.
   **[SAY]** "Config is encrypted per-environment and read in-process. No
   redeploy to shift traffic."

5. **[DO]** Flip to 100% v2.
   **[DO]** `curl /services/orders_v2/call` repeatedly.
   **[SCREEN]** All rows now in v2 shape after reads.
   **[SAY]** "Lazy migration: every read upgrades a row. After traffic has
   covered the working set, the table is migrated."

6. **[DO]** Simulate a problem, flip the config back to v1.
   **[SAY]** "Rollback is a config edit. The v1 service was still there. No
   redeploy, no outage."

7. **[SCREEN]** Slide: "Canary + migration + rollback, no tools required."

---

## Suggested sequences

- **The 5-minute pitch** — Demo 2 standalone. Fastest wow; hardest to
  misinterpret.
- **"Why Unison on the BEAM"** — Demo 1 → Demo 4. Content addressing sells
  itself, time travel is the payoff.
- **"Platform, not framework"** — Demo 3 → Demo 6. Composition and ops in one
  story.
- **Full tech talk (~25 min)** — Demo 2 (hook) → Demo 1 (mechanism) → Demo 3
  (composition) → Demo 5 (scale) → Demo 4 (close).

## What to have on hand

- A pre-warmed Unison project on Share so `push` is instant.
- UCM sessions open in separate terminals — no switching contexts mid-demo.
- A monitoring pane tailing each node's log.
- Pre-baked `mainDeploy` functions in the demo `.u` file so you never type a
  hash by hand.
- A fallback recorded video for the two demos most likely to fail live (1 and
  5, because they depend on cluster + external LLM).
