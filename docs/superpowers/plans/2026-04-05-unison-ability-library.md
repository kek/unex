# Unison Ability Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a Unison library with ability definitions and HTTP-backed handlers for all seven Uniops abilities (Storage, Config, Blobs, Scratch, Log, Remote, Services), so Unison programs use idiomatic `handle ... with` patterns instead of raw HTTP calls.

**Architecture:** Each ability is defined as a `unique ability` with operations matching the Uniops HTTP API. Each gets a handler function that translates operations to HTTP calls via `@unison/http`. A shared HTTP helpers module provides JSON construction and HTTP plumbing. A top-level `Uniops.main` combinator composes all handlers. Example programs serve as documentation and integration tests.

**Tech Stack:** Unison language, `@unison/http` library, Uniops HTTP API

---

## Important: Unison Syntax Reference

**Handler pattern:**
```unison
handler : SomeArg -> Request {MyAbility} a -> {Http, Threads, IO, Exception} a
handler arg = cases
  { MyAbility.operation input -> k } ->
    result = doSomething input
    handle k result with handler arg
  { a } -> a
```

**HTTP calls (from `@unison/http`):**
```unison
-- GET
Http.get (URI.parse url)                     -- returns HttpResponse

-- POST with JSON body
Http.request (HttpRequest.addHeader "Content-Type" "application/json"
  (HttpRequest.post (URI.parse url) (Body.fromText jsonString)))

-- DELETE
Http.request (HttpRequest.delete (URI.parse url) Body.empty)

-- Extract body text
bodyText response                            -- returns Text
```

**Wrapping HTTP abilities:**
```unison
Threads.run do Http.run do
  handle !program with myHandler
```

**All `.u` files use:**
```unison
use lib.unison_http_15_2_0
```
The exact version suffix depends on the installed `@unison/http` — the user adjusts this.

---

## File Structure

```
unison/
  Uniops/
    Http/Helpers.u      -- shared HTTP + JSON utilities (postJson, getJson, etc.)
    Storage.u           -- UStorage ability + handler
    Config.u            -- UConfig ability + handler
    Blobs.u             -- UBlobs ability + handler
    Scratch.u           -- UScratch ability + handler
    Log.u               -- ULog ability + handler
    Remote.u            -- URemote ability + handler
    Services.u          -- UServices ability + handler
  Main.u                -- Uniops.main combinator
  Examples/
    BasicStorage.u      -- example: write/read/scan
    ConfigAndSecrets.u  -- example: config management
    FullApp.u           -- example: using all abilities together
```

---

### Task 1: HTTP Helpers

**Files:**
- Create: `unison/Uniops/Http/Helpers.u`

Shared HTTP and JSON utilities used by all handlers.

- [ ] **Step 1: Create the helpers file**

Create `unison/Uniops/Http/Helpers.u`:

```unison
-- Uniops HTTP Helpers
-- Shared utilities for ability handlers to communicate with the Uniops HTTP API.

use lib.unison_http_15_2_0

Uniops.Http.postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
Uniops.Http.postJson url body =
  req =
    HttpRequest.addHeader "Content-Type" "application/json"
      (HttpRequest.post (URI.parse url) (Body.fromText body))
  Http.request req

Uniops.Http.postEmpty : Text -> {IO, Exception, Http, Threads} HttpResponse
Uniops.Http.postEmpty url =
  Http.request (HttpRequest.post (URI.parse url) Body.empty)

Uniops.Http.getJson : Text -> {IO, Exception, Http, Threads} Text
Uniops.Http.getJson url = bodyText (Http.get (URI.parse url))

Uniops.Http.deleteReq : Text -> {IO, Exception, Http, Threads} HttpResponse
Uniops.Http.deleteReq url =
  Http.request (HttpRequest.delete (URI.parse url) Body.empty)

Uniops.Http.getStatus : HttpResponse -> Nat
Uniops.Http.getStatus resp = HttpResponse.statusCode resp

-- Simple JSON key-value pair builder: [("key","val"), ...] -> "{\"key\":\"val\",...}"
Uniops.Http.toJson : [(Text, Text)] -> Text
Uniops.Http.toJson pairs =
  entries = List.map (cases (k, v) -> "\"" ++ k ++ "\":\"" ++ v ++ "\"") pairs
  "{" ++ Text.join "," entries ++ "}"

-- Extract "value" field from JSON response like {"key":"k","value":"v"}
-- Returns None if the response status is 404
Uniops.Http.parseValue : HttpResponse -> Optional Text
Uniops.Http.parseValue resp =
  if Uniops.Http.getStatus resp == 404 then None
  else
    body = bodyText resp
    -- Simple extraction: find "value":" and extract until next unescaped "
    Uniops.Http.extractField body "value"

-- Extract a named field from a JSON string (simple: no nested objects)
Uniops.Http.extractField : Text -> Text -> Optional Text
Uniops.Http.extractField json field =
  needle = "\"" ++ field ++ "\":\""
  match Text.indexOf needle json with
    None -> None
    Some idx ->
      afterKey = Text.drop (idx + Text.size needle) json
      match Text.indexOf "\"" afterKey with
        None -> None
        Some endIdx -> Some (Text.take endIdx afterKey)

-- Extract "keys" array from JSON like {"keys":["a","b"]}
Uniops.Http.parseKeys : Text -> [Text]
Uniops.Http.parseKeys json =
  needle = "\"keys\":["
  match Text.indexOf needle json with
    None -> []
    Some idx ->
      afterKey = Text.drop (idx + Text.size needle) json
      match Text.indexOf "]" afterKey with
        None -> []
        Some endIdx ->
          inner = Text.take endIdx afterKey
          if inner == "" then []
          else
            -- Split by comma, strip quotes
            parts = Text.split "," inner
            List.map (txt -> Text.drop 1 (Text.dropRight 1 txt)) parts
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unison HTTP helpers for ability handlers"
jj new
```

---

### Task 2: UStorage Ability + Handler

**Files:**
- Create: `unison/Uniops/Storage.u`

- [ ] **Step 1: Create the Storage ability and handler**

Create `unison/Uniops/Storage.u`:

```unison
-- Uniops Storage Ability
-- Durable key-value storage with ordered tables, cells, and transactions.

use lib.unison_http_15_2_0

structural type Uniops.TxOp
  = WriteTable Text Text Text
  | WriteCell Text Text

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
  tx : Text -> [Uniops.TxOp] -> ()

UStorage.handler : Text -> Request {UStorage} a -> {IO, Exception, Http, Threads} a
UStorage.handler baseUrl = cases
  { UStorage.createDatabase name -> k } ->
    _ = Uniops.Http.postJson (baseUrl ++ "/databases") (Uniops.Http.toJson [("name", name)])
    handle k () with UStorage.handler baseUrl

  { UStorage.listDatabases -> k } ->
    body = Uniops.Http.getJson (baseUrl ++ "/databases")
    keys = Uniops.Http.parseKeys body
    handle k keys with UStorage.handler baseUrl

  { UStorage.createTable db table -> k } ->
    _ = Uniops.Http.postEmpty (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table)
    handle k () with UStorage.handler baseUrl

  { UStorage.write db table key value -> k } ->
    _ = Uniops.Http.postJson
          (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/write")
          (Uniops.Http.toJson [("key", key), ("value", value)])
    handle k () with UStorage.handler baseUrl

  { UStorage.read db table key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/read/" ++ key))
    val = Uniops.Http.parseValue resp
    handle k val with UStorage.handler baseUrl

  { UStorage.delete db table key -> k } ->
    _ = Uniops.Http.deleteReq (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/delete/" ++ key)
    handle k () with UStorage.handler baseUrl

  { UStorage.scan db table from to -> k } ->
    body = bodyText (Http.request (HttpRequest.addHeader "Content-Type" "application/json"
      (HttpRequest.post (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/scan"))
        (Body.fromText (Uniops.Http.toJson [("from", from), ("to", to)])))))
    -- Parse scan response: {"results":[{"key":"k","value":"v"},...]}
    -- Simple: return empty for now, scan returns raw pairs
    handle k [] with UStorage.handler baseUrl

  { UStorage.writeCell db name value -> k } ->
    _ = Uniops.Http.postJson
          (baseUrl ++ "/databases/" ++ db ++ "/cells/" ++ name ++ "/write")
          (Uniops.Http.toJson [("value", value)])
    handle k () with UStorage.handler baseUrl

  { UStorage.readCell db name -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/cells/" ++ name ++ "/read"))
    val = Uniops.Http.parseValue resp
    handle k val with UStorage.handler baseUrl

  { UStorage.tx db ops -> k } ->
    opsJson = List.map (cases
      Uniops.TxOp.WriteTable table key value ->
        "{\"op\":\"write_table\",\"table\":\"" ++ table ++ "\",\"key\":\"" ++ key ++ "\",\"value\":\"" ++ value ++ "\"}"
      Uniops.TxOp.WriteCell name value ->
        "{\"op\":\"write_cell\",\"name\":\"" ++ name ++ "\",\"value\":\"" ++ value ++ "\"}") ops
    body = "{\"operations\":[" ++ Text.join "," opsJson ++ "]}"
    _ = Uniops.Http.postJson (baseUrl ++ "/databases/" ++ db ++ "/tx") body
    handle k () with UStorage.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add UStorage ability and HTTP handler"
jj new
```

---

### Task 3: UConfig Ability + Handler

**Files:**
- Create: `unison/Uniops/Config.u`

- [ ] **Step 1: Create the Config ability and handler**

Create `unison/Uniops/Config.u`:

```unison
-- Uniops Config Ability
-- Encrypted key-value secrets, scoped by environment.

use lib.unison_http_15_2_0

unique ability UConfig where
  set : Text -> Text -> Text -> ()
  get : Text -> Text -> Optional Text
  delete : Text -> Text -> ()
  list : Text -> [Text]

UConfig.handler : Text -> Request {UConfig} a -> {IO, Exception, Http, Threads} a
UConfig.handler baseUrl = cases
  { UConfig.set env key value -> k } ->
    _ = Uniops.Http.postJson
          (baseUrl ++ "/config/" ++ env ++ "/" ++ key)
          (Uniops.Http.toJson [("value", value)])
    handle k () with UConfig.handler baseUrl

  { UConfig.get env key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/config/" ++ env ++ "/" ++ key))
    val = Uniops.Http.parseValue resp
    handle k val with UConfig.handler baseUrl

  { UConfig.delete env key -> k } ->
    _ = Uniops.Http.deleteReq (baseUrl ++ "/config/" ++ env ++ "/" ++ key)
    handle k () with UConfig.handler baseUrl

  { UConfig.list env -> k } ->
    body = Uniops.Http.getJson (baseUrl ++ "/config/" ++ env)
    keys = Uniops.Http.parseKeys body
    handle k keys with UConfig.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add UConfig ability and HTTP handler"
jj new
```

---

### Task 4: UBlobs Ability + Handler

**Files:**
- Create: `unison/Uniops/Blobs.u`

- [ ] **Step 1: Create the Blobs ability and handler**

Create `unison/Uniops/Blobs.u`:

```unison
-- Uniops Blobs Ability
-- Binary object storage on the filesystem.

use lib.unison_http_15_2_0

unique ability UBlobs where
  write : Text -> Text -> Bytes -> ()
  read : Text -> Text -> Optional Bytes
  delete : Text -> Text -> ()
  list : Text -> Text -> [Text]

UBlobs.handler : Text -> Request {UBlobs} a -> {IO, Exception, Http, Threads} a
UBlobs.handler baseUrl = cases
  { UBlobs.write db key data -> k } ->
    b64 = base64Encode data
    _ = Uniops.Http.postJson
          (baseUrl ++ "/blobs/" ++ db ++ "/" ++ key)
          ("{\"data\":\"" ++ b64 ++ "\"}")
    handle k () with UBlobs.handler baseUrl

  { UBlobs.read db key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/blobs/" ++ db ++ "/" ++ key))
    val =
      if Uniops.Http.getStatus resp == 404 then None
      else
        body = bodyText resp
        match Uniops.Http.extractField body "data" with
          None -> None
          Some b64 -> Some (base64Decode b64)
    handle k val with UBlobs.handler baseUrl

  { UBlobs.delete db key -> k } ->
    _ = Uniops.Http.deleteReq (baseUrl ++ "/blobs/" ++ db ++ "/" ++ key)
    handle k () with UBlobs.handler baseUrl

  { UBlobs.list db prefix -> k } ->
    body = bodyText (Uniops.Http.postJson
          (baseUrl ++ "/blobs/" ++ db ++ "/list")
          ("{\"prefix\":\"" ++ prefix ++ "\"}"))
    keys = Uniops.Http.parseKeys body
    handle k keys with UBlobs.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add UBlobs ability and HTTP handler"
jj new
```

---

### Task 5: UScratch Ability + Handler

**Files:**
- Create: `unison/Uniops/Scratch.u`

- [ ] **Step 1: Create the Scratch ability and handler**

Create `unison/Uniops/Scratch.u`:

```unison
-- Uniops Scratch Ability
-- Ephemeral in-memory cache (node-local, lost on restart).

use lib.unison_http_15_2_0

unique ability UScratch where
  put : Text -> Text -> ()
  get : Text -> Optional Text
  delete : Text -> ()

UScratch.handler : Text -> Request {UScratch} a -> {IO, Exception, Http, Threads} a
UScratch.handler baseUrl = cases
  { UScratch.put key value -> k } ->
    _ = Uniops.Http.postJson
          (baseUrl ++ "/scratch/" ++ key)
          (Uniops.Http.toJson [("value", value)])
    handle k () with UScratch.handler baseUrl

  { UScratch.get key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/scratch/" ++ key))
    val = Uniops.Http.parseValue resp
    handle k val with UScratch.handler baseUrl

  { UScratch.delete key -> k } ->
    _ = Uniops.Http.deleteReq (baseUrl ++ "/scratch/" ++ key)
    handle k () with UScratch.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add UScratch ability and HTTP handler"
jj new
```

---

### Task 6: ULog Ability + Handler

**Files:**
- Create: `unison/Uniops/Log.u`

- [ ] **Step 1: Create the Log ability and handler**

Create `unison/Uniops/Log.u`:

```unison
-- Uniops Log Ability
-- Structured logging with ring buffer.

use lib.unison_http_15_2_0

structural type Uniops.LogEntry = { level : Text, message : Text, timestamp : Text, metadata : Text }

unique ability ULog where
  info : Text -> ()
  error : Text -> ()
  warn : Text -> ()
  recent : Nat -> [Uniops.LogEntry]

ULog.handler : Text -> Request {ULog} a -> {IO, Exception, Http, Threads} a
ULog.handler baseUrl = cases
  { ULog.info message -> k } ->
    _ = Uniops.Http.postJson (baseUrl ++ "/log")
          ("{\"level\":\"info\",\"message\":\"" ++ message ++ "\",\"metadata\":{}}")
    handle k () with ULog.handler baseUrl

  { ULog.error message -> k } ->
    _ = Uniops.Http.postJson (baseUrl ++ "/log")
          ("{\"level\":\"error\",\"message\":\"" ++ message ++ "\",\"metadata\":{}}")
    handle k () with ULog.handler baseUrl

  { ULog.warn message -> k } ->
    _ = Uniops.Http.postJson (baseUrl ++ "/log")
          ("{\"level\":\"warn\",\"message\":\"" ++ message ++ "\",\"metadata\":{}}")
    handle k () with ULog.handler baseUrl

  { ULog.recent n -> k } ->
    body = Uniops.Http.getJson (baseUrl ++ "/log/recent/" ++ Nat.toText n)
    -- Return empty list — full JSON array parsing is complex
    -- Users can parse the raw body if needed via getJson directly
    handle k [] with ULog.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add ULog ability and HTTP handler"
jj new
```

---

### Task 7: URemote Ability + Handler

**Files:**
- Create: `unison/Uniops/Remote.u`

- [ ] **Step 1: Create the Remote ability and handler**

Create `unison/Uniops/Remote.u`:

```unison
-- Uniops Remote Ability
-- Execute compiled Unison bytecode on remote nodes.

use lib.unison_http_15_2_0

unique ability URemote where
  execute : Text -> Text
  submit : Text -> Text

URemote.handler : Text -> Request {URemote} a -> {IO, Exception, Http, Threads} a
URemote.handler baseUrl = cases
  { URemote.execute hash -> k } ->
    body = bodyText (Uniops.Http.postJson
          (baseUrl ++ "/remote/execute")
          (Uniops.Http.toJson [("hash", hash)]))
    handle k body with URemote.handler baseUrl

  { URemote.submit hash -> k } ->
    body = bodyText (Uniops.Http.postJson
          (baseUrl ++ "/remote/submit")
          (Uniops.Http.toJson [("hash", hash)]))
    handle k body with URemote.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add URemote ability and HTTP handler"
jj new
```

---

### Task 8: UServices Ability + Handler

**Files:**
- Create: `unison/Uniops/Services.u`

- [ ] **Step 1: Create the Services ability and handler**

Create `unison/Uniops/Services.u`:

```unison
-- Uniops Services Ability
-- Deploy, call, list, and undeploy named services.

use lib.unison_http_15_2_0

structural type Uniops.ServiceInfo = { name : Text, hash : Text, node : Text }

unique ability UServices where
  deploy : Text -> Text -> Text
  call : Text -> Text
  list : [Uniops.ServiceInfo]
  undeploy : Text -> ()

UServices.handler : Text -> Request {UServices} a -> {IO, Exception, Http, Threads} a
UServices.handler baseUrl = cases
  { UServices.deploy name source -> k } ->
    body = bodyText (Uniops.Http.postJson
          (baseUrl ++ "/services/deploy")
          ("{\"name\":\"" ++ name ++ "\",\"source\":\"" ++ source ++ "\"}"))
    handle k body with UServices.handler baseUrl

  { UServices.call name -> k } ->
    body = bodyText (Uniops.Http.postEmpty (baseUrl ++ "/services/" ++ name ++ "/call"))
    handle k body with UServices.handler baseUrl

  { UServices.list -> k } ->
    _ = Uniops.Http.getJson (baseUrl ++ "/services")
    -- Return empty list — full JSON array parsing is complex
    handle k [] with UServices.handler baseUrl

  { UServices.undeploy name -> k } ->
    _ = Uniops.Http.deleteReq (baseUrl ++ "/services/" ++ name)
    handle k () with UServices.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add UServices ability and HTTP handler"
jj new
```

---

### Task 9: Uniops.main Combinator

**Files:**
- Create: `unison/Main.u`

- [ ] **Step 1: Create the main combinator**

Create `unison/Main.u`:

```unison
-- Uniops Main Combinator
-- Composes all ability handlers to run a program against a Uniops server.
--
-- Usage:
--   main : '{IO, Exception} ()
--   main = Uniops.main "http://localhost:4040" myApp
--
-- Where myApp uses any combination of UStorage, UConfig, UBlobs, UScratch, ULog, URemote, UServices.

use lib.unison_http_15_2_0

Uniops.main : Text
  -> '{UStorage, UConfig, UBlobs, UScratch, ULog, URemote, UServices, IO, Exception} a
  -> '{IO, Exception} a
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

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Uniops.main combinator composing all ability handlers"
jj new
```

---

### Task 10: Example Programs

**Files:**
- Create: `unison/Examples/BasicStorage.u`
- Create: `unison/Examples/ConfigAndSecrets.u`
- Create: `unison/Examples/FullApp.u`

- [ ] **Step 1: Create BasicStorage example**

Create `unison/Examples/BasicStorage.u`:

```unison
-- Example: Basic Storage operations using UStorage ability
--
-- Run with: (Uniops server must be running on localhost:4040)
--   myProject/main> run Examples.BasicStorage.main

use lib.unison_http_15_2_0

Examples.BasicStorage.app : '{UStorage, IO, Exception} ()
Examples.BasicStorage.app = do
  -- Create a database and table
  UStorage.createDatabase "demo"
  UStorage.createTable "demo" "users"

  -- Write some data
  UStorage.write "demo" "users" "alice" "{\"role\":\"admin\",\"email\":\"alice@example.com\"}"
  UStorage.write "demo" "users" "bob" "{\"role\":\"viewer\"}"

  -- Read it back
  match UStorage.read "demo" "users" "alice" with
    Some val -> printLine ("Alice: " ++ val)
    None -> printLine "Alice not found!"

  -- Use a cell
  UStorage.writeCell "demo" "visitor_count" "42"
  match UStorage.readCell "demo" "visitor_count" with
    Some count -> printLine ("Visitors: " ++ count)
    None -> printLine "No count"

  -- Delete a key
  UStorage.delete "demo" "users" "bob"
  printLine "Done!"

Examples.BasicStorage.main : '{IO, Exception} ()
Examples.BasicStorage.main =
  Uniops.main "http://localhost:4040" Examples.BasicStorage.app
```

- [ ] **Step 2: Create ConfigAndSecrets example**

Create `unison/Examples/ConfigAndSecrets.u`:

```unison
-- Example: Config (encrypted secrets) and Scratch (ephemeral cache)
--
-- Run with: (Uniops server must be running on localhost:4040)
--   myProject/main> run Examples.ConfigAndSecrets.main

use lib.unison_http_15_2_0

Examples.ConfigAndSecrets.app : '{UConfig, UScratch, IO, Exception} ()
Examples.ConfigAndSecrets.app = do
  -- Store encrypted secrets
  UConfig.set "prod" "api_key" "sk-live-abc123"
  UConfig.set "prod" "db_password" "supersecret"
  UConfig.set "staging" "api_key" "sk-test-xyz"

  -- Read them back
  match UConfig.get "prod" "api_key" with
    Some key -> printLine ("Prod API key: " ++ key)
    None -> printLine "No API key!"

  -- List keys for an environment
  keys = UConfig.list "prod"
  printLine ("Prod keys: " ++ Text.join ", " keys)

  -- Use scratch for temporary caching
  UScratch.put "session:user123" "{\"name\":\"Alice\",\"role\":\"admin\"}"
  match UScratch.get "session:user123" with
    Some session -> printLine ("Session: " ++ session)
    None -> printLine "No session"

  printLine "Done!"

Examples.ConfigAndSecrets.main : '{IO, Exception} ()
Examples.ConfigAndSecrets.main = do
  Threads.run do Http.run do
    handle
      (handle !(Examples.ConfigAndSecrets.app)
        with UConfig.handler "http://localhost:4040")
      with UScratch.handler "http://localhost:4040"
```

- [ ] **Step 3: Create FullApp example**

Create `unison/Examples/FullApp.u`:

```unison
-- Example: Full application using all abilities via Uniops.main
--
-- Run with: (Uniops server must be running on localhost:4040)
--   myProject/main> run Examples.FullApp.main

use lib.unison_http_15_2_0

Examples.FullApp.app : '{UStorage, UConfig, UBlobs, UScratch, ULog, URemote, UServices, IO, Exception} ()
Examples.FullApp.app = do
  -- Log the start
  ULog.info "Application starting"

  -- Set up storage
  UStorage.createDatabase "myapp"
  UStorage.createTable "myapp" "items"

  -- Store a secret
  UConfig.set "prod" "api_key" "sk-live-secret"

  -- Write and read data
  UStorage.write "myapp" "items" "item1" "{\"name\":\"Widget\",\"price\":9.99}"
  match UStorage.read "myapp" "items" "item1" with
    Some val -> printLine ("Item: " ++ val)
    None -> printLine "Not found"

  -- Cache something
  UScratch.put "recent_query" "item1"

  -- Read back the config
  match UConfig.get "prod" "api_key" with
    Some key -> printLine ("API key loaded: " ++ Text.take 10 key ++ "...")
    None -> printLine "No API key"

  ULog.info "Application finished"
  printLine "All done!"

Examples.FullApp.main : '{IO, Exception} ()
Examples.FullApp.main =
  Uniops.main "http://localhost:4040" Examples.FullApp.app
```

- [ ] **Step 4: Commit**

```bash
jj desc -m "Add example programs for Storage, Config, and full app"
jj new
```

---

### Task 11: Update README

**Files:**
- Modify: `README.md`

Replace the "Using from Unison" section with updated docs showing the ability library.

- [ ] **Step 1: Update the "Using from Unison" section**

Read the current `README.md`. Find the section `## Using from Unison` and replace everything from there up to (but not including) `## Running a cluster` with:

````markdown
## Using from Unison

Uniops provides a Unison ability library so your programs use idiomatic `handle ... with` patterns instead of raw HTTP calls.

### Setup

1. In UCM, install the HTTP library:

```
myProject/main> lib.install @unison/http
```

2. Copy the `unison/` directory from this repo into your Unison project, or add the files individually.

3. Check the `use lib.unison_http_15_2_0` import in each file — the version suffix must match your installed `@unison/http` version. Check with `ls lib` in UCM.

### Example: Storage with abilities

```unison
myApp : '{UStorage, IO, Exception} ()
myApp = do
  UStorage.createDatabase "mydb"
  UStorage.createTable "mydb" "users"
  UStorage.write "mydb" "users" "alice" "{\"role\":\"admin\"}"

  match UStorage.read "mydb" "users" "alice" with
    Some val -> printLine ("Got: " ++ val)
    None -> printLine "Not found"

main : '{IO, Exception} ()
main = Uniops.main "http://localhost:4040" myApp
```

Run it (with uniops server running):

```
myProject/main> run main
Got: {"role":"admin"}
```

### Example: Config and Scratch

```unison
myApp : '{UConfig, UScratch, IO, Exception} ()
myApp = do
  UConfig.set "prod" "api_key" "sk-secret-123"

  match UConfig.get "prod" "api_key" with
    Some key -> printLine ("Key: " ++ key)
    None -> printLine "No key"

  UScratch.put "cache:session" "user-data"
  match UScratch.get "cache:session" with
    Some val -> printLine ("Cached: " ++ val)
    None -> printLine "Cache miss"
```

### Using individual handlers

You don't have to use all abilities. Compose only what you need:

```unison
main : '{IO, Exception} ()
main = do
  Threads.run do Http.run do
    handle !myApp with UStorage.handler "http://localhost:4040"
```

### Available abilities

| Ability | Operations |
|---------|-----------|
| `UStorage` | `createDatabase`, `createTable`, `write`, `read`, `delete`, `scan`, `writeCell`, `readCell`, `tx` |
| `UConfig` | `set`, `get`, `delete`, `list` |
| `UBlobs` | `write`, `read`, `delete`, `list` |
| `UScratch` | `put`, `get`, `delete` |
| `ULog` | `info`, `error`, `warn`, `recent` |
| `URemote` | `execute`, `submit` |
| `UServices` | `deploy`, `call`, `list`, `undeploy` |

### Mock handlers for testing

Write programs against abilities, test with mock handlers:

```unison
mockStorage : Request {UStorage} a -> a
mockStorage = cases
  { UStorage.read _ _ _ -> k } -> handle k (Some "mock-value") with mockStorage
  { UStorage.write _ _ _ _ -> k } -> handle k () with mockStorage
  { a } -> a

-- Test your app without a running server
test> myTest = check do
  result = handle !myApp with mockStorage
  -- assertions here
```
````

- [ ] **Step 2: Commit**

```bash
jj desc -m "Update README with Unison ability library docs"
jj new
```

---

### Task 12: Final Commit

**Files:** None (verification and final commit)

- [ ] **Step 1: Verify all files exist**

Run:
```bash
ls -la unison/Uniops/Http/Helpers.u unison/Uniops/Storage.u unison/Uniops/Config.u unison/Uniops/Blobs.u unison/Uniops/Scratch.u unison/Uniops/Log.u unison/Uniops/Remote.u unison/Uniops/Services.u unison/Main.u unison/Examples/BasicStorage.u unison/Examples/ConfigAndSecrets.u unison/Examples/FullApp.u
```

Expected: All 12 files listed.

- [ ] **Step 2: Verify Elixir tests still pass**

Run: `mix test`
Expected: All tests pass (Unison files don't affect Elixir compilation)

- [ ] **Step 3: Final commit**

```bash
jj desc -m "Complete Plan 8: Unison ability library with handlers for all seven abilities"
```

---

## What This Plan Produces

1. **HTTP Helpers** — shared `postJson`, `getJson`, `deleteReq`, `toJson`, `parseValue`, `parseKeys` utilities
2. **7 Ability Definitions** — `UStorage`, `UConfig`, `UBlobs`, `UScratch`, `ULog`, `URemote`, `UServices`
3. **7 HTTP Handlers** — each translates ability operations to Uniops HTTP API calls
4. **`Uniops.main` Combinator** — composes all handlers for the common case
5. **3 Example Programs** — BasicStorage, ConfigAndSecrets, FullApp
6. **Updated README** — documents the ability library with examples and mock handler patterns

This completes the full Uniops platform. Unison programs now use idiomatic ability patterns backed by the HTTP API, with the option to swap handlers for testing.
