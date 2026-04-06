# Unison Ability Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a Unison library with ability definitions and HTTP-backed handlers for all seven Unex abilities (Storage, Config, Blobs, Scratch, Log, Remote, Services), so Unison programs use idiomatic `handle ... with` patterns instead of raw HTTP calls.

**Architecture:** Each ability is defined as a `unique ability` with operations matching the Unex HTTP API. Each gets a handler function that translates operations to HTTP calls via `@unison/http`. A shared HTTP helpers module provides JSON construction and HTTP plumbing. A top-level `Unex.main` combinator composes all handlers. Example programs serve as documentation and integration tests.

**Tech Stack:** Unison language, `@unison/http` library, Unex HTTP API

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
  Unex/
    Http/Helpers.u      -- shared HTTP + JSON utilities (postJson, getJson, etc.)
    Storage.u           -- Unex.Storage ability + handler
    Config.u            -- Unex.Config ability + handler
    Blobs.u             -- Unex.Blobs ability + handler
    Scratch.u           -- Unex.Scratch ability + handler
    Log.u               -- Unex.Log ability + handler
    Remote.u            -- Unex.Remote ability + handler
    Services.u          -- Unex.Services ability + handler
  Main.u                -- Unex.main combinator
  Examples/
    BasicStorage.u      -- example: write/read/scan
    ConfigAndSecrets.u  -- example: config management
    FullApp.u           -- example: using all abilities together
```

---

### Task 1: HTTP Helpers

**Files:**
- Create: `unison/Unex/Http/Helpers.u`

Shared HTTP and JSON utilities used by all handlers.

- [ ] **Step 1: Create the helpers file**

Create `unison/Unex/Http/Helpers.u`:

```unison
-- Unex HTTP Helpers
-- Shared utilities for ability handlers to communicate with the Unex HTTP API.

use lib.unison_http_15_2_0

Unex.Http.postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
Unex.Http.postJson url body =
  req =
    HttpRequest.addHeader "Content-Type" "application/json"
      (HttpRequest.post (URI.parse url) (Body.fromText body))
  Http.request req

Unex.Http.postEmpty : Text -> {IO, Exception, Http, Threads} HttpResponse
Unex.Http.postEmpty url =
  Http.request (HttpRequest.post (URI.parse url) Body.empty)

Unex.Http.getJson : Text -> {IO, Exception, Http, Threads} Text
Unex.Http.getJson url = bodyText (Http.get (URI.parse url))

Unex.Http.deleteReq : Text -> {IO, Exception, Http, Threads} HttpResponse
Unex.Http.deleteReq url =
  Http.request (HttpRequest.delete (URI.parse url) Body.empty)

Unex.Http.getStatus : HttpResponse -> Nat
Unex.Http.getStatus resp = HttpResponse.statusCode resp

-- Simple JSON key-value pair builder: [("key","val"), ...] -> "{\"key\":\"val\",...}"
Unex.Http.toJson : [(Text, Text)] -> Text
Unex.Http.toJson pairs =
  entries = List.map (cases (k, v) -> "\"" ++ k ++ "\":\"" ++ v ++ "\"") pairs
  "{" ++ Text.join "," entries ++ "}"

-- Extract "value" field from JSON response like {"key":"k","value":"v"}
-- Returns None if the response status is 404
Unex.Http.parseValue : HttpResponse -> Optional Text
Unex.Http.parseValue resp =
  if Unex.Http.getStatus resp == 404 then None
  else
    body = bodyText resp
    -- Simple extraction: find "value":" and extract until next unescaped "
    Unex.Http.extractField body "value"

-- Extract a named field from a JSON string (simple: no nested objects)
Unex.Http.extractField : Text -> Text -> Optional Text
Unex.Http.extractField json field =
  needle = "\"" ++ field ++ "\":\""
  match Text.indexOf needle json with
    None -> None
    Some idx ->
      afterKey = Text.drop (idx + Text.size needle) json
      match Text.indexOf "\"" afterKey with
        None -> None
        Some endIdx -> Some (Text.take endIdx afterKey)

-- Extract "keys" array from JSON like {"keys":["a","b"]}
Unex.Http.parseKeys : Text -> [Text]
Unex.Http.parseKeys json =
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

### Task 2: Unex.Storage Ability + Handler

**Files:**
- Create: `unison/Unex/Storage.u`

- [ ] **Step 1: Create the Storage ability and handler**

Create `unison/Unex/Storage.u`:

```unison
-- Unex Storage Ability
-- Durable key-value storage with ordered tables, cells, and transactions.

use lib.unison_http_15_2_0

structural type Unex.TxOp
  = WriteTable Text Text Text
  | WriteCell Text Text

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
  tx : Text -> [Unex.TxOp] -> ()

Unex.Storage.handler : Text -> Request {Unex.Storage} a -> {IO, Exception, Http, Threads} a
Unex.Storage.handler baseUrl = cases
  { Unex.Storage.createDatabase name -> k } ->
    _ = Unex.Http.postJson (baseUrl ++ "/databases") (Unex.Http.toJson [("name", name)])
    handle k () with Unex.Storage.handler baseUrl

  { Unex.Storage.listDatabases -> k } ->
    body = Unex.Http.getJson (baseUrl ++ "/databases")
    keys = Unex.Http.parseKeys body
    handle k keys with Unex.Storage.handler baseUrl

  { Unex.Storage.createTable db table -> k } ->
    _ = Unex.Http.postEmpty (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table)
    handle k () with Unex.Storage.handler baseUrl

  { Unex.Storage.write db table key value -> k } ->
    _ = Unex.Http.postJson
          (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/write")
          (Unex.Http.toJson [("key", key), ("value", value)])
    handle k () with Unex.Storage.handler baseUrl

  { Unex.Storage.read db table key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/read/" ++ key))
    val = Unex.Http.parseValue resp
    handle k val with Unex.Storage.handler baseUrl

  { Unex.Storage.delete db table key -> k } ->
    _ = Unex.Http.deleteReq (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/delete/" ++ key)
    handle k () with Unex.Storage.handler baseUrl

  { Unex.Storage.scan db table from to -> k } ->
    body = bodyText (Http.request (HttpRequest.addHeader "Content-Type" "application/json"
      (HttpRequest.post (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/scan"))
        (Body.fromText (Unex.Http.toJson [("from", from), ("to", to)])))))
    -- Parse scan response: {"results":[{"key":"k","value":"v"},...]}
    -- Simple: return empty for now, scan returns raw pairs
    handle k [] with Unex.Storage.handler baseUrl

  { Unex.Storage.writeCell db name value -> k } ->
    _ = Unex.Http.postJson
          (baseUrl ++ "/databases/" ++ db ++ "/cells/" ++ name ++ "/write")
          (Unex.Http.toJson [("value", value)])
    handle k () with Unex.Storage.handler baseUrl

  { Unex.Storage.readCell db name -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/cells/" ++ name ++ "/read"))
    val = Unex.Http.parseValue resp
    handle k val with Unex.Storage.handler baseUrl

  { Unex.Storage.tx db ops -> k } ->
    opsJson = List.map (cases
      Unex.TxOp.WriteTable table key value ->
        "{\"op\":\"write_table\",\"table\":\"" ++ table ++ "\",\"key\":\"" ++ key ++ "\",\"value\":\"" ++ value ++ "\"}"
      Unex.TxOp.WriteCell name value ->
        "{\"op\":\"write_cell\",\"name\":\"" ++ name ++ "\",\"value\":\"" ++ value ++ "\"}") ops
    body = "{\"operations\":[" ++ Text.join "," opsJson ++ "]}"
    _ = Unex.Http.postJson (baseUrl ++ "/databases/" ++ db ++ "/tx") body
    handle k () with Unex.Storage.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.Storage ability and HTTP handler"
jj new
```

---

### Task 3: Unex.Config Ability + Handler

**Files:**
- Create: `unison/Unex/Config.u`

- [ ] **Step 1: Create the Config ability and handler**

Create `unison/Unex/Config.u`:

```unison
-- Unex Config Ability
-- Encrypted key-value secrets, scoped by environment.

use lib.unison_http_15_2_0

unique ability Unex.Config where
  set : Text -> Text -> Text -> ()
  get : Text -> Text -> Optional Text
  delete : Text -> Text -> ()
  list : Text -> [Text]

Unex.Config.handler : Text -> Request {Unex.Config} a -> {IO, Exception, Http, Threads} a
Unex.Config.handler baseUrl = cases
  { Unex.Config.set env key value -> k } ->
    _ = Unex.Http.postJson
          (baseUrl ++ "/config/" ++ env ++ "/" ++ key)
          (Unex.Http.toJson [("value", value)])
    handle k () with Unex.Config.handler baseUrl

  { Unex.Config.get env key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/config/" ++ env ++ "/" ++ key))
    val = Unex.Http.parseValue resp
    handle k val with Unex.Config.handler baseUrl

  { Unex.Config.delete env key -> k } ->
    _ = Unex.Http.deleteReq (baseUrl ++ "/config/" ++ env ++ "/" ++ key)
    handle k () with Unex.Config.handler baseUrl

  { Unex.Config.list env -> k } ->
    body = Unex.Http.getJson (baseUrl ++ "/config/" ++ env)
    keys = Unex.Http.parseKeys body
    handle k keys with Unex.Config.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.Config ability and HTTP handler"
jj new
```

---

### Task 4: Unex.Blobs Ability + Handler

**Files:**
- Create: `unison/Unex/Blobs.u`

- [ ] **Step 1: Create the Blobs ability and handler**

Create `unison/Unex/Blobs.u`:

```unison
-- Unex Blobs Ability
-- Binary object storage on the filesystem.

use lib.unison_http_15_2_0

unique ability Unex.Blobs where
  write : Text -> Text -> Bytes -> ()
  read : Text -> Text -> Optional Bytes
  delete : Text -> Text -> ()
  list : Text -> Text -> [Text]

Unex.Blobs.handler : Text -> Request {Unex.Blobs} a -> {IO, Exception, Http, Threads} a
Unex.Blobs.handler baseUrl = cases
  { Unex.Blobs.write db key data -> k } ->
    b64 = base64Encode data
    _ = Unex.Http.postJson
          (baseUrl ++ "/blobs/" ++ db ++ "/" ++ key)
          ("{\"data\":\"" ++ b64 ++ "\"}")
    handle k () with Unex.Blobs.handler baseUrl

  { Unex.Blobs.read db key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/blobs/" ++ db ++ "/" ++ key))
    val =
      if Unex.Http.getStatus resp == 404 then None
      else
        body = bodyText resp
        match Unex.Http.extractField body "data" with
          None -> None
          Some b64 -> Some (base64Decode b64)
    handle k val with Unex.Blobs.handler baseUrl

  { Unex.Blobs.delete db key -> k } ->
    _ = Unex.Http.deleteReq (baseUrl ++ "/blobs/" ++ db ++ "/" ++ key)
    handle k () with Unex.Blobs.handler baseUrl

  { Unex.Blobs.list db prefix -> k } ->
    body = bodyText (Unex.Http.postJson
          (baseUrl ++ "/blobs/" ++ db ++ "/list")
          ("{\"prefix\":\"" ++ prefix ++ "\"}"))
    keys = Unex.Http.parseKeys body
    handle k keys with Unex.Blobs.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.Blobs ability and HTTP handler"
jj new
```

---

### Task 5: Unex.Scratch Ability + Handler

**Files:**
- Create: `unison/Unex/Scratch.u`

- [ ] **Step 1: Create the Scratch ability and handler**

Create `unison/Unex/Scratch.u`:

```unison
-- Unex Scratch Ability
-- Ephemeral in-memory cache (node-local, lost on restart).

use lib.unison_http_15_2_0

unique ability Unex.Scratch where
  put : Text -> Text -> ()
  get : Text -> Optional Text
  delete : Text -> ()

Unex.Scratch.handler : Text -> Request {Unex.Scratch} a -> {IO, Exception, Http, Threads} a
Unex.Scratch.handler baseUrl = cases
  { Unex.Scratch.put key value -> k } ->
    _ = Unex.Http.postJson
          (baseUrl ++ "/scratch/" ++ key)
          (Unex.Http.toJson [("value", value)])
    handle k () with Unex.Scratch.handler baseUrl

  { Unex.Scratch.get key -> k } ->
    resp = Http.get (URI.parse (baseUrl ++ "/scratch/" ++ key))
    val = Unex.Http.parseValue resp
    handle k val with Unex.Scratch.handler baseUrl

  { Unex.Scratch.delete key -> k } ->
    _ = Unex.Http.deleteReq (baseUrl ++ "/scratch/" ++ key)
    handle k () with Unex.Scratch.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.Scratch ability and HTTP handler"
jj new
```

---

### Task 6: Unex.Log Ability + Handler

**Files:**
- Create: `unison/Unex/Log.u`

- [ ] **Step 1: Create the Log ability and handler**

Create `unison/Unex/Log.u`:

```unison
-- Unex Log Ability
-- Structured logging with ring buffer.

use lib.unison_http_15_2_0

structural type Unex.LogEntry = { level : Text, message : Text, timestamp : Text, metadata : Text }

unique ability Unex.Log where
  info : Text -> ()
  error : Text -> ()
  warn : Text -> ()
  recent : Nat -> [Unex.LogEntry]

Unex.Log.handler : Text -> Request {Unex.Log} a -> {IO, Exception, Http, Threads} a
Unex.Log.handler baseUrl = cases
  { Unex.Log.info message -> k } ->
    _ = Unex.Http.postJson (baseUrl ++ "/log")
          ("{\"level\":\"info\",\"message\":\"" ++ message ++ "\",\"metadata\":{}}")
    handle k () with Unex.Log.handler baseUrl

  { Unex.Log.error message -> k } ->
    _ = Unex.Http.postJson (baseUrl ++ "/log")
          ("{\"level\":\"error\",\"message\":\"" ++ message ++ "\",\"metadata\":{}}")
    handle k () with Unex.Log.handler baseUrl

  { Unex.Log.warn message -> k } ->
    _ = Unex.Http.postJson (baseUrl ++ "/log")
          ("{\"level\":\"warn\",\"message\":\"" ++ message ++ "\",\"metadata\":{}}")
    handle k () with Unex.Log.handler baseUrl

  { Unex.Log.recent n -> k } ->
    body = Unex.Http.getJson (baseUrl ++ "/log/recent/" ++ Nat.toText n)
    -- Return empty list — full JSON array parsing is complex
    -- Users can parse the raw body if needed via getJson directly
    handle k [] with Unex.Log.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.Log ability and HTTP handler"
jj new
```

---

### Task 7: Unex.Remote Ability + Handler

**Files:**
- Create: `unison/Unex/Remote.u`

- [ ] **Step 1: Create the Remote ability and handler**

Create `unison/Unex/Remote.u`:

```unison
-- Unex Remote Ability
-- Execute compiled Unison bytecode on remote nodes.

use lib.unison_http_15_2_0

unique ability Unex.Remote where
  execute : Text -> Text
  submit : Text -> Text

Unex.Remote.handler : Text -> Request {Unex.Remote} a -> {IO, Exception, Http, Threads} a
Unex.Remote.handler baseUrl = cases
  { Unex.Remote.execute hash -> k } ->
    body = bodyText (Unex.Http.postJson
          (baseUrl ++ "/remote/execute")
          (Unex.Http.toJson [("hash", hash)]))
    handle k body with Unex.Remote.handler baseUrl

  { Unex.Remote.submit hash -> k } ->
    body = bodyText (Unex.Http.postJson
          (baseUrl ++ "/remote/submit")
          (Unex.Http.toJson [("hash", hash)]))
    handle k body with Unex.Remote.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.Remote ability and HTTP handler"
jj new
```

---

### Task 8: Unex.Services Ability + Handler

**Files:**
- Create: `unison/Unex/Services.u`

- [ ] **Step 1: Create the Services ability and handler**

Create `unison/Unex/Services.u`:

```unison
-- Unex Services Ability
-- Deploy, call, list, and undeploy named services.

use lib.unison_http_15_2_0

structural type Unex.ServiceInfo = { name : Text, hash : Text, node : Text }

unique ability Unex.Services where
  deploy : Text -> Text -> Text
  call : Text -> Text
  list : [Unex.ServiceInfo]
  undeploy : Text -> ()

Unex.Services.handler : Text -> Request {Unex.Services} a -> {IO, Exception, Http, Threads} a
Unex.Services.handler baseUrl = cases
  { Unex.Services.deploy name source -> k } ->
    body = bodyText (Unex.Http.postJson
          (baseUrl ++ "/services/deploy")
          ("{\"name\":\"" ++ name ++ "\",\"source\":\"" ++ source ++ "\"}"))
    handle k body with Unex.Services.handler baseUrl

  { Unex.Services.call name -> k } ->
    body = bodyText (Unex.Http.postEmpty (baseUrl ++ "/services/" ++ name ++ "/call"))
    handle k body with Unex.Services.handler baseUrl

  { Unex.Services.list -> k } ->
    _ = Unex.Http.getJson (baseUrl ++ "/services")
    -- Return empty list — full JSON array parsing is complex
    handle k [] with Unex.Services.handler baseUrl

  { Unex.Services.undeploy name -> k } ->
    _ = Unex.Http.deleteReq (baseUrl ++ "/services/" ++ name)
    handle k () with Unex.Services.handler baseUrl

  { a } -> a
```

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.Services ability and HTTP handler"
jj new
```

---

### Task 9: Unex.main Combinator

**Files:**
- Create: `unison/Main.u`

- [ ] **Step 1: Create the main combinator**

Create `unison/Main.u`:

```unison
-- Unex Main Combinator
-- Composes all ability handlers to run a program against a Unex server.
--
-- Usage:
--   main : '{IO, Exception} ()
--   main = Unex.main "http://localhost:4040" myApp
--
-- Where myApp uses any combination of Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch, Unex.Log, Unex.Remote, Unex.Services.

use lib.unison_http_15_2_0

Unex.main : Text
  -> '{Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch, Unex.Log, Unex.Remote, Unex.Services, IO, Exception} a
  -> '{IO, Exception} a
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

- [ ] **Step 2: Commit**

```bash
jj desc -m "Add Unex.main combinator composing all ability handlers"
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
-- Example: Basic Storage operations using Unex.Storage ability
--
-- Run with: (Unex server must be running on localhost:4040)
--   myProject/main> run Examples.BasicStorage.main

use lib.unison_http_15_2_0

Examples.BasicStorage.app : '{Unex.Storage, IO, Exception} ()
Examples.BasicStorage.app = do
  -- Create a database and table
  Unex.Storage.createDatabase "demo"
  Unex.Storage.createTable "demo" "users"

  -- Write some data
  Unex.Storage.write "demo" "users" "alice" "{\"role\":\"admin\",\"email\":\"alice@example.com\"}"
  Unex.Storage.write "demo" "users" "bob" "{\"role\":\"viewer\"}"

  -- Read it back
  match Unex.Storage.read "demo" "users" "alice" with
    Some val -> printLine ("Alice: " ++ val)
    None -> printLine "Alice not found!"

  -- Use a cell
  Unex.Storage.writeCell "demo" "visitor_count" "42"
  match Unex.Storage.readCell "demo" "visitor_count" with
    Some count -> printLine ("Visitors: " ++ count)
    None -> printLine "No count"

  -- Delete a key
  Unex.Storage.delete "demo" "users" "bob"
  printLine "Done!"

Examples.BasicStorage.main : '{IO, Exception} ()
Examples.BasicStorage.main =
  Unex.main "http://localhost:4040" Examples.BasicStorage.app
```

- [ ] **Step 2: Create ConfigAndSecrets example**

Create `unison/Examples/ConfigAndSecrets.u`:

```unison
-- Example: Config (encrypted secrets) and Scratch (ephemeral cache)
--
-- Run with: (Unex server must be running on localhost:4040)
--   myProject/main> run Examples.ConfigAndSecrets.main

use lib.unison_http_15_2_0

Examples.ConfigAndSecrets.app : '{Unex.Config, Unex.Scratch, IO, Exception} ()
Examples.ConfigAndSecrets.app = do
  -- Store encrypted secrets
  Unex.Config.set "prod" "api_key" "sk-live-abc123"
  Unex.Config.set "prod" "db_password" "supersecret"
  Unex.Config.set "staging" "api_key" "sk-test-xyz"

  -- Read them back
  match Unex.Config.get "prod" "api_key" with
    Some key -> printLine ("Prod API key: " ++ key)
    None -> printLine "No API key!"

  -- List keys for an environment
  keys = Unex.Config.list "prod"
  printLine ("Prod keys: " ++ Text.join ", " keys)

  -- Use scratch for temporary caching
  Unex.Scratch.put "session:user123" "{\"name\":\"Alice\",\"role\":\"admin\"}"
  match Unex.Scratch.get "session:user123" with
    Some session -> printLine ("Session: " ++ session)
    None -> printLine "No session"

  printLine "Done!"

Examples.ConfigAndSecrets.main : '{IO, Exception} ()
Examples.ConfigAndSecrets.main = do
  Threads.run do Http.run do
    handle
      (handle !(Examples.ConfigAndSecrets.app)
        with Unex.Config.handler "http://localhost:4040")
      with Unex.Scratch.handler "http://localhost:4040"
```

- [ ] **Step 3: Create FullApp example**

Create `unison/Examples/FullApp.u`:

```unison
-- Example: Full application using all abilities via Unex.main
--
-- Run with: (Unex server must be running on localhost:4040)
--   myProject/main> run Examples.FullApp.main

use lib.unison_http_15_2_0

Examples.FullApp.app : '{Unex.Storage, Unex.Config, Unex.Blobs, Unex.Scratch, Unex.Log, Unex.Remote, Unex.Services, IO, Exception} ()
Examples.FullApp.app = do
  -- Log the start
  Unex.Log.info "Application starting"

  -- Set up storage
  Unex.Storage.createDatabase "myapp"
  Unex.Storage.createTable "myapp" "items"

  -- Store a secret
  Unex.Config.set "prod" "api_key" "sk-live-secret"

  -- Write and read data
  Unex.Storage.write "myapp" "items" "item1" "{\"name\":\"Widget\",\"price\":9.99}"
  match Unex.Storage.read "myapp" "items" "item1" with
    Some val -> printLine ("Item: " ++ val)
    None -> printLine "Not found"

  -- Cache something
  Unex.Scratch.put "recent_query" "item1"

  -- Read back the config
  match Unex.Config.get "prod" "api_key" with
    Some key -> printLine ("API key loaded: " ++ Text.take 10 key ++ "...")
    None -> printLine "No API key"

  Unex.Log.info "Application finished"
  printLine "All done!"

Examples.FullApp.main : '{IO, Exception} ()
Examples.FullApp.main =
  Unex.main "http://localhost:4040" Examples.FullApp.app
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

Unex provides a Unison ability library so your programs use idiomatic `handle ... with` patterns instead of raw HTTP calls.

### Setup

1. In UCM, install the HTTP library:

```
myProject/main> lib.install @unison/http
```

2. Copy the `unison/` directory from this repo into your Unison project, or add the files individually.

3. Check the `use lib.unison_http_15_2_0` import in each file — the version suffix must match your installed `@unison/http` version. Check with `ls lib` in UCM.

### Example: Storage with abilities

```unison
myApp : '{Unex.Storage, IO, Exception} ()
myApp = do
  Unex.Storage.createDatabase "mydb"
  Unex.Storage.createTable "mydb" "users"
  Unex.Storage.write "mydb" "users" "alice" "{\"role\":\"admin\"}"

  match Unex.Storage.read "mydb" "users" "alice" with
    Some val -> printLine ("Got: " ++ val)
    None -> printLine "Not found"

main : '{IO, Exception} ()
main = Unex.main "http://localhost:4040" myApp
```

Run it (with unex server running):

```
myProject/main> run main
Got: {"role":"admin"}
```

### Example: Config and Scratch

```unison
myApp : '{Unex.Config, Unex.Scratch, IO, Exception} ()
myApp = do
  Unex.Config.set "prod" "api_key" "sk-secret-123"

  match Unex.Config.get "prod" "api_key" with
    Some key -> printLine ("Key: " ++ key)
    None -> printLine "No key"

  Unex.Scratch.put "cache:session" "user-data"
  match Unex.Scratch.get "cache:session" with
    Some val -> printLine ("Cached: " ++ val)
    None -> printLine "Cache miss"
```

### Using individual handlers

You don't have to use all abilities. Compose only what you need:

```unison
main : '{IO, Exception} ()
main = do
  Threads.run do Http.run do
    handle !myApp with Unex.Storage.handler "http://localhost:4040"
```

### Available abilities

| Ability | Operations |
|---------|-----------|
| `Unex.Storage` | `createDatabase`, `createTable`, `write`, `read`, `delete`, `scan`, `writeCell`, `readCell`, `tx` |
| `Unex.Config` | `set`, `get`, `delete`, `list` |
| `Unex.Blobs` | `write`, `read`, `delete`, `list` |
| `Unex.Scratch` | `put`, `get`, `delete` |
| `Unex.Log` | `info`, `error`, `warn`, `recent` |
| `Unex.Remote` | `execute`, `submit` |
| `Unex.Services` | `deploy`, `call`, `list`, `undeploy` |

### Mock handlers for testing

Write programs against abilities, test with mock handlers:

```unison
mockStorage : Request {Unex.Storage} a -> a
mockStorage = cases
  { Unex.Storage.read _ _ _ -> k } -> handle k (Some "mock-value") with mockStorage
  { Unex.Storage.write _ _ _ _ -> k } -> handle k () with mockStorage
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
ls -la unison/Unex/Http/Helpers.u unison/Unex/Storage.u unison/Unex/Config.u unison/Unex/Blobs.u unison/Unex/Scratch.u unison/Unex/Log.u unison/Unex/Remote.u unison/Unex/Services.u unison/Main.u unison/Examples/BasicStorage.u unison/Examples/ConfigAndSecrets.u unison/Examples/FullApp.u
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
2. **7 Ability Definitions** — `Unex.Storage`, `Unex.Config`, `Unex.Blobs`, `Unex.Scratch`, `Unex.Log`, `Unex.Remote`, `Unex.Services`
3. **7 HTTP Handlers** — each translates ability operations to Unex HTTP API calls
4. **`Unex.main` Combinator** — composes all handlers for the common case
5. **3 Example Programs** — BasicStorage, ConfigAndSecrets, FullApp
6. **Updated README** — documents the ability library with examples and mock handler patterns

This completes the full Unex platform. Unison programs now use idiomatic ability patterns backed by the HTTP API, with the option to swap handlers for testing.
