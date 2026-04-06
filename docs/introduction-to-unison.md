# Introduction to Unison

> **Note:** This document was AI-generated from various online Unison resources. References are listed at the bottom but may not be exhaustive. If you have any corrections or reservations, please get in touch.

## Part I — The Big Idea: Content-Addressed Code

Unison is a statically-typed, purely functional programming language built around one radical premise: **every definition is identified by a hash of its syntax tree**, not by its name. Names are just separately stored metadata — pointers into a vast, immutable address space. When you write a function like `increment n = n + 1`, Unison replaces all named arguments with positional references and all dependencies with their hashes, then hashes the resulting syntax tree using 512-bit SHA3. The chance of collision is negligible on cosmological timescales.

This content-addressing is not an implementation detail; it's the conceptual foundation from which every other feature flows. Because definitions never change (we may reassign names, but the thing at a given hash is eternal), Unison achieves: no builds (parse and typecheck once, cache forever), no dependency conflicts (different versions of the same library simply have different hashes and coexist peacefully), typed durable storage (serialize a hash-identified value and deserialize it years later without version mismatch), instant non-breaking renames, and simplified distributed programming (ship bytecode by hash, sync missing dependencies on the fly).

The implication for your daily workflow is profound. Your codebase is not a bag of mutable text files. It's an append-only, content-addressed database managed by the **Unison Codebase Manager (UCM)**. You still author code in your favorite text editor as `.u` scratch files, but once you save, UCM parses, typechecks, and offers to store the result. From that point on, the definition lives in the database, and UCM pretty-prints it back to your editor whenever you want to read or edit it. Code formatting is automatic and consistent — it's just a rendering of the stored AST.

---

## Part II — Getting Started: Installation and the UCM

### Installation

On macOS, use Homebrew: `brew install unisonweb/unison/ucm`. On Linux (Debian/Ubuntu), add the Unison apt repository and `apt install unisonweb`. You can also download a tarball directly from the GitHub releases page for Mac and Linux (`ucm-linux-x64.tar.gz` or `ucm-macos-x64.tar.gz`). Running `ucm` for the first time initializes a codebase at `$HOME/.unison`.

### Editor Setup

VS Code has a first-party Unison extension providing syntax highlighting, LSP-based autocomplete, error highlighting, type-on-hover, and documentation previews. Vim and Atom also have community syntax support. The UCM also has an MCP (Model Context Protocol) setup for AI-assisted development.

### Projects and Branches

The codebase is subdivided into **projects**, each of which can have multiple **branches**. Create a project with `project.create myProject`, which automatically provisions a `main` branch and downloads the `base` standard library into a special `lib` namespace. The UCM prompt reflects your current project and branch (e.g., `myProject/main>`). All commands are scoped to the current project/branch context.

### The Core Workflow Loop

1. Write Unison code in a `.u` scratch file.
2. Save. UCM watches the filesystem, typechecks your code, and reports results.
3. If it typechecks, run `update` (or `add` for brand-new definitions) to persist it to the codebase.
4. Use `run myFunction` to execute, or `compile myFunction outputName` to produce a native binary (`.uc` file).

Watch expressions beginning with `>` evaluate immediately on save and display results in the UCM console, giving you a REPL-like experience without leaving your editor.

---

## Part III — Language Fundamentals

### Terms, Types, and Values

Term declarations have two parts: an optional type signature and an implementation. Types are capitalized (`Text`, `Nat`); term names are camelCase. Values are immutable — reassigning a name in the same file causes a typecheck error.

The primitive types are: `Nat` (64-bit unsigned), `Int` (64-bit signed, prefixed with `+`), `Float` (64-bit), `Text` (string data), `Char` (single character, prefixed with `?`), `Bytes` (byte literals like `0xsdeadbeef`), and `Boolean`.

Tuples group heterogeneous values: `("Alice", 5) : (Text, Nat)`. Extract elements with `at1`, `at2`, etc., or use tuple pattern decomposition inside a function body: `(first, second) = myTuple`.

### Functions

Functions are first-class values. A function taking a `Nat` and returning a `Text` has the type `Nat -> Text`. Multi-argument functions are curried: `add : Nat -> Nat -> Nat` means `add` takes one `Nat` and returns a function that takes another `Nat`. Unison supports anonymous lambdas (`x -> x + 1`), the `cases` keyword for pattern-matching lambdas, and partial application.

The pipe operator `|>` threads a value through a chain of functions left-to-right, and `<|` does the reverse. Function composition uses `>>` (left-to-right) and `<<` (right-to-left).

### Delayed Computations (Thunks)

A value of type `'a` (pronounced "delayed a") is a computation that, when forced, produces an `a`. You create one with `do` (for blocks) or the `'` prefix (for expressions): `delayed = 'printLine "hello"`. Force it with `!delayed`. This distinction between a value and a computation-that-produces-a-value is central to how Unison handles effects.

### Collections

Lists are constructed with `[1, 2, 3]` and have type `[Nat]`. They support the usual FP operations (`List.map`, `List.filter`, `List.foldLeft`, etc.). `Map` is an immutable key-value collection (`Map.fromList`, `Map.insert`, `Map.lookup`). `Set` provides unordered unique collections.

### Control Flow

`if condition then expr1 else expr2` works as expected. Pattern matching is done with `match value with` followed by cases, and supports constructor patterns, literal patterns, list patterns (`head +: tail`, `init :+ last`), tuple patterns, as-patterns (`x@(Pair a b)`), guard patterns (`| condition`), and blank patterns (`_`).

Looping is done via recursion, often with a `go` helper function and tail-call optimization, or more idiomatically through higher-order functions like `List.map`, `List.foldLeft`, etc.

### User-Defined Data Types

Unison has two kinds of types: **unique** and **structural**. A `unique type` gets a hash that incorporates a random nonce at creation time, so two independently created types with identical structure are nonetheless distinct. A `structural type` is hashed purely from its structure, so structurally identical types are the same type. Most application-level types should be `unique`; `structural` is for types where structural identity is the right notion (like generic pairs).

```
unique type Color = Red | Green | Blue

structural type Pair a b = Pair a b
```

**Record types** are a syntactic convenience: `unique type Person = { name : Text, age : Nat }` auto-generates accessor functions `Person.name : Person -> Text` and `Person.age : Person -> Nat`, plus a modifier function pattern.

### Operators

Custom infix operators are defined with symbolic names. Operator precedence in Unison follows a fixed set of rules based on the operator's leading character. Use backticks to call a regular function infix: `` 3 `add` 5 ``.

---

## Hands-On Tutorial: Learning Unison Step by Step

This chapter walks through Unison's core features with concrete code you can type into a scratch file and run. It assumes you have UCM installed and a project created (`project.create tutorial`). Open `scratch.u` in your editor alongside UCM.

### Step 1: Your First Definition

Type this into `scratch.u` and save:

```
greeting : Text
greeting = "Hello from Unison!"
```

UCM will respond with something like: "These new definitions are ok to add." Type `add` in UCM to persist it. You've just stored a term in the codebase. Note that `greeting` has a type signature (`Text`) and an implementation. Unison inferred the type, but writing it explicitly is good practice.

Now add a watch expression to see the value. Append this to your scratch file:

```
> greeting
```

Save, and UCM evaluates the expression and prints "Hello from Unison!" in the console. Watch expressions (lines starting with `>`) are your REPL.

### Step 2: Writing Functions

Clear your scratch file and write a function:

```
square : Nat -> Nat
square x = x Nat.* x
```

The `use Nat *` clause lets you write `x * x` instead of `x Nat.* x`. Rewrite it more idiomatically:

```
square : Nat -> Nat
square x =
  use Nat *
  x * x

> square 7
```

Save. UCM shows 49. Now write a two-argument function:

```
addNums : Nat -> Nat -> Nat
addNums a b =
  use Nat +
  a + b

> addNums 10 32
```

The result is 42. Functions in Unison are curried, so `addNums 10` is itself a function of type `Nat -> Nat`. You can exploit this:

```
addTen : Nat -> Nat
addTen = addNums 10

> addTen 5
```

Result: 15.

### Step 3: Collections and Transformations

Lists are created with square brackets:

```
fruits : [Text]
fruits = ["apple", "banana", "cherry"]

> List.map Text.toUppercase fruits
```

Result: `["APPLE", "BANANA", "CHERRY"]`. You can chain operations with the pipe operator:

```
> [1, 2, 3, 4, 5]
    |> List.filter (x -> Nat.mod x 2 == 0)
    |> List.map (x -> x Nat.* x)
```

Result: `[4, 16]` — filter to even numbers, then square them.

### Step 4: Custom Data Types

Define a unique type with multiple constructors:

```
unique type Color = Red | Green | Blue

colorName : Color -> Text
colorName = cases
  Red   -> "red"
  Green -> "green"
  Blue  -> "blue"

> colorName Blue
```

Result: "blue". The `cases` keyword creates a pattern-matching lambda. You can also use `match ... with`:

```
describe : Color -> Text
describe c = match c with
  Red   -> "the color of fire"
  Green -> "the color of grass"
  Blue  -> "the color of sky"
```

Now try a parameterized type:

```
unique type Box a = Empty | Full a

unbox : a -> Box a -> a
unbox default = cases
  Empty  -> default
  Full x -> x

> unbox 0 (Full 42)
> unbox 0 Empty
```

Results: 42, then 0.

### Step 5: Record Types

Records auto-generate accessor and modifier functions:

```
unique type Person = { name : Text, age : Nat }

alice : Person
alice = Person "Alice" 30

> Person.name alice
> Person.age alice
```

Results: "Alice", then 30.

### Step 6: Delayed Computations and IO

A value of type `'a` (tick-a) is a thunk — a computation that hasn't run yet. The `do` keyword creates one:

```
myAction : '{IO, Exception} ()
myAction = do
  printLine "What is your name?"
  name = !console.getLine
  printLine ("Hello, " Text.++ name Text.++ "!")
```

Run it with UCM: `run myAction`. The program will prompt you for input, read a line, and greet you. Notice `!console.getLine` — the `!` forces (evaluates) the thunk returned by `console.getLine`.

### Step 7: Pattern Matching on Lists

Unison supports powerful list patterns:

```
describeList : [a] -> Text
describeList = cases
  []        -> "empty"
  [_]       -> "one element"
  [_, _]    -> "two elements"
  _ +: rest -> "more than two elements"

> describeList [1, 2, 3]
> describeList ([] : [Nat])
```

The `+:` operator destructures a list into head and tail. You can also use `:+` to match from the end.

### Step 8: Recursion and Looping

Unison has no `for` or `while` loops. You use recursion or higher-order functions:

```
factorial : Nat -> Nat
factorial n =
  use Nat *
  if n == 0 then 1 else n * factorial (Nat.drop n 1)

> factorial 10
```

Result: 3628800. For the idiomatic approach, use library functions:

```
> List.foldLeft (acc x -> acc Nat.* x) 1 (Nat.range 1 11)
```

Same result, no explicit recursion.

### Step 9: Writing and Running Tests

Tests use the `test>` watch expression:

```
test> square.test1 = check (square 5 == 25)
test> square.test2 = check (square 0 == 0)
```

Save, and UCM reports whether each test passed. Add them to the codebase with `add`, then run `test square` to re-execute them. Unison caches test results — if you haven't changed `square` or its dependencies, the tests report from cache instantly.

For property-based testing:

```
test> square.prop = test.verify do
  Each.repeat 100
  n = natIn 0 1000
  test.ensureEqual (square n) (n Nat.* n)
```

This generates 100 random inputs and checks the property for each.

### Step 10: Installing a Library and Using It

Install a library from Unison Share:

```
tutorial/main> lib.install @unison/http
```

UCM downloads the library into your `lib` namespace. Now you can write code that uses it:

```
fetchExample : '{IO, Exception, Threads} HttpResponse
fetchExample = do
  uri = net.URI.parse "https://httpbin.org/get"
  req = do Http.get uri
  Http.run req
```

Run it with `run fetchExample` to make an actual HTTP request.

### Where to Go Next

You now have hands-on experience with terms, functions, currying, collections, custom types, records, IO, pattern matching, recursion, testing, and library installation. The rest of this guide covers abilities (Part IV), which is the most distinctive feature of Unison, followed by testing in depth, codebase management, and the Cloud platform.

---

## Part IV — Abilities (Algebraic Effects)

### The Mental Model

Abilities are Unison's implementation of algebraic effects and handlers. They let you express effectful computations (I/O, state, randomness, exceptions, logging, etc.) in a way that separates the *description* of an effect from its *implementation*.

Think of it like a generalized try/catch. When a function calls an ability operation, execution pauses and jumps to the relevant handler, which can inspect the operation, perform some action, and then *resume* the computation with a value. The handler sees a continuation — the "rest of the program" — and decides what to do with it.

### Abilities in Type Signatures

Abilities appear in curly braces in function types. A function `getText : '{IO, Exception} Text` is a delayed computation that, when forced, may perform IO and may raise exceptions. A function `pure : Nat -> Nat` has no abilities — it's guaranteed pure. The typechecker enforces this: you can't call an ability operation in a context that doesn't list that ability.

`IO` is the built-in ability for real-world side effects (console, file system, network). `Exception` represents potentially failing computations. You'll also see `Random`, `STM` (software transactional memory), and `Remote` (for distributed computation).

### Using Abilities

The `do` keyword creates a thunk that can use abilities. Inside a `do` block, you can call ability operations freely, and the required abilities are inferred and propagated upward in the type signature.

```
greet : '{IO, Exception} ()
greet = do
  name = !console.getLine
  printLine ("Hello, " ++ name)
```

### Writing Custom Abilities

Define an ability with its operations:

```
unique ability Store v where
  get : v
  put : v -> ()
```

Write a handler using `handle ... with` and pattern-matching on `Request` constructors. The handler receives each ability operation plus a continuation `k` representing the rest of the computation:

```
storeHandler : v -> Request {Store v} a -> a
storeHandler state = cases
  { Store.get -> k }    -> handle k state with storeHandler state
  { Store.put v -> k }  -> handle k () with storeHandler v
  { a }                 -> a
```

The final pattern `{ a }` matches when the computation completes without further ability requests — it returns the final value.

### Abilities vs. Monads

For those coming from Haskell: abilities are comparable to free monads or mtl-style monad transformers, but with a crucial ergonomic advantage — they compose automatically. You don't need monad transformer stacks or `lift`. A function requiring `{Store Text, Exception}` just works; the abilities are unioned, not stacked.

---

## Part V — Testing

### Test Watch Expressions

Tests are written as `test>` watch expressions in scratch files. The result type must be `[Result]`. Unison caches test results by dependency hash — deterministic tests only rerun if their dependency graph changes.

```
test> myTest = check (factorial 5 == 120)
```

Run tests with `test` (all tests) or `test namespace.path` (scoped). Use `io.test` for tests that require the `IO` ability.

### Property-Based Testing with `test.verify`

`test.verify` accepts a block using `Random`, `Each`, `Exception`, and `Label` abilities. Use `Each.repeat 100` to generate many random cases, `Random.nat()` for random values, and assertion functions like `test.ensureEqual`, `ensure`, `ensureGreater`, etc.

```
test> roundTrip = test.verify do
  Each.repeat 100
  n = Random.nat()
  test.ensureEqual (Nat.fromText (Nat.toText n)) (Some n)
```

Use `labeled "section" do ...` to add scoped labels that appear in failure output, pinpointing which assertion in a multi-assertion test failed.

---

## Part VI — Codebase Management and Tooling

### UCM Commands (Key Reference)

- `project.create name` — create a new project with `main` branch
- `add` — add new definitions from scratch file
- `update` — add or replace definitions, updating dependents
- `run function` — execute a function
- `compile function output` — produce a native binary
- `test` / `test namespace` — run tests
- `find pattern` — search definitions by name
- `view definition` — display a definition
- `edit definition` — load a definition into the scratch file for editing
- `move.term` / `move.type` — rename
- `delete.term` / `delete.type` — remove
- `merge branch` — merge a branch into current
- `branch.create name` — create a new branch
- `push` / `pull` — sync with Unison Share
- `lib.install @user/project` — install a dependency
- `ui` — open the local codebase browser

### Unison Share

Unison Share (share.unison-lang.org) is the code hosting platform for Unison projects. It provides fully hyperlinked code browsing, rich documentation rendering, and acts as the registry for library distribution. You push projects with `push` and pull dependencies with `lib.install`. Projects on Share can be public or private.

### UCM Desktop App

A graphical interface for browsing your codebase, viewing projects and dependencies. It currently supports browsing and viewing but is growing toward full codebase management and direct editing.

### Documentation

Unison's doc format is built into the language. Documentation blocks use `{{ ... }}` syntax and produce values of type `Doc`. They support Markdown-like formatting, inline typechecked code snippets, embedded evaluated expressions, hyperlinks, tables, and even Mermaid diagrams. Anonymous doc blocks placed immediately before a definition are automatically associated with that definition.

### Transcripts

Transcript files (`.md` files with fenced UCM command blocks) let you script UCM sessions for reproducible demonstrations, integration tests, or documentation generation.

### Profiling

Unison supports profiling programs to identify performance bottlenecks, accessible through UCM commands.

### Docker

The documentation covers running Unison programs in Docker containers for deployment scenarios outside of Unison Cloud.

---

## Part VII — Unison Cloud Platform: How It Actually Works

### Core Concepts

Unison Cloud is a managed runtime that provides handlers for a specific set of abilities: `Remote`, `Storage`, `Http`, `Services`, `Config`, `Blobs`, `Scratch`, `Log`, `Random`, and `WebSockets`. When you write `Cloud.main do ...`, the code inside that block can use all these abilities freely, and the Cloud runtime provides the handler implementations. This is the key architectural point: the Cloud is not a separate deployment target — it is a set of *ability handlers* backed by real infrastructure.

### The Deployment Protocol

When you call `deploy env myService`, the runtime serializes the bytecode tree of `myService` (identified by its content hash), enumerates all transitive dependencies (also by hash), and ships them to a compute node in the cluster. The receiving node checks its local code cache for which hashes it already has, requests any missing ones from the sender, caches them, and starts execution. This is why deployment takes seconds, not minutes — there are no containers to build, no images to push. The unit of deployment is individual Unison definitions, not multi-gigabyte artifacts.

Three requirements make this possible, and all three are satisfied by the open-source language: (1) all values in the language are serializable, (2) the runtime can enumerate dependencies of any value at the granularity of individual definitions, and (3) content-addressing eliminates dependency conflicts entirely. What the *Cloud* adds is the actual networking, compute pool, and storage fabric that runs this protocol in production.

### Services

Services are typed, versioned, Cloud-hosted functions identified by a `ServiceHash`. Deploy the same code, get the same hash; change the code, get a new hash. You can assign a stable `ServiceName` for always pointing to the latest deployment. Service-to-service calls use a native protocol (not HTTP) that supports approximately 100-microsecond typed calls with no JSON or Protobuf serialization — just Unison's hash-based wire format, fully typechecked.

```
main = Cloud.main do
  myService = deploy !Environment.default Nat.toText
  Cloud.submit !Environment.default do
    Services.call myService 42
```

### The Remote Ability

`Remote` is the lowest-level primitive for distributed execution. It allows forking computations to different nodes in the cluster and awaiting their results. Higher-level abstractions are built on top: `Seq` (distributed datasets for map-reduce), Volturno (a stream-processing framework analogous to Kafka Streams or Flink), and Daemons (long-running processes that the runtime automatically restarts on node crashes or redeploys).

All cloud computations use `Remote` as their runtime, supplemented by abilities like `Http`, `Storage`, `Scratch`, `Services`, `Config`, `Log`, `Blobs`, and `Random`. The `toRemote` helper function handles all these cloud abilities within the `Remote` runtime.

### Storage Internals

Cloud storage types include `Database` (top-level container), `OrderedTable` (sorted key-value with range queries and transactions), `Cell` (single durable value), `Blobs` (binary object storage), `Batch` (batched multi-table reads), `Config` (encrypted secrets), `Scratch` (ephemeral in-memory cache), and `Table` (lower-level key-value primitive).

The storage layer is backed by DynamoDB in the current AWS region, with likely S3 for blob storage. The typed Unison interface hides this completely — you never write SQL, JSON encoding, or serialization code. Values are persisted using Unison's content-addressed serialization format, which means you can store arbitrary Unison values (including functions) and read them back without version conflicts, ever. All durable operations go through the `Storage` ability, with atomic multi-table updates via `Transaction`. Database creation is lightweight and idempotent.

### Environments and Access Management

`Environment` groups Cloud resources for basic access control. Only services running in the same Environment as a Database can read/write its data. Encrypted secrets are loaded via `Environment.setValue` and retrieved at runtime with `Environment.Config.expect`.

### Local Development

You can develop Cloud applications locally using `Cloud.main.local.serve`, which runs your services on your own machine before deploying to the Cloud.

---

## Part VIII — Distributed Programming and the Open-Source / Proprietary Boundary

### What's Open-Source

The Unison language (MIT-licensed) provides every primitive needed for distribution: content-addressed code (so computations are relocatable by hash), universal serialization of all values, and runtime dependency enumeration. Unison Share (Haskell + PostgreSQL backend, Elm frontend) was open-sourced in May 2024 because it's central to the developer experience.

### What's Proprietary

The production-grade handler for `Remote` — the networking layer, compute pool, node discovery, hash-syncing protocol, supervisor/worker model, and the durable storage fabric — is provided by Unison Cloud. The orchestration layer is written in Unison itself. The FAQ states directly: "Currently, we don't have an easy way for folks to run and manage a distributed Unison program on their own cluster."

Nobody in the community has built a self-hosted handler for `Remote`. The architecture makes it theoretically feasible — the ability system means anyone could write a handler using, say, TCP sockets between UCM instances — but it would be a substantial engineering project and nobody has started one publicly.

### Unison Cloud vs. BYOC

**From the programmer's perspective, Unison Cloud and BYOC are functional workalikes.** The API is identical: same `Cloud.main`, same `deploy`, same `Storage`, same `Remote`. Your Unison code doesn't change between hosted Cloud and BYOC.

The difference is operational. In hosted Cloud, Unison Computing runs the compute nodes in their AWS region. In BYOC, you run the nodes yourself: Unison Computing provides a container image and environment variables, you launch as many instances as you want on your own infrastructure (AWS, GCP, Azure, on-prem Kubernetes), and you have a cluster in minutes. You can scale up or down dynamically.

There is one architectural asymmetry: Unison Computing still operates a lightweight multi-tenant control plane for managing BYOC clusters, but it has no access to the data inside them. All data and HTTP request traffic stays on your infrastructure. This means BYOC is not fully air-gapped — the control plane handles cluster coordination metadata — but the compute and storage are yours. BYOC pricing is free for personal/non-commercial use (up to 10 nodes), or $80/month per node plus $15/month per user and per service for commercial use.

### The Practical Upshot

If distributed programming is your primary reason for choosing Unison, the Cloud ecosystem (managed or BYOC) is the supported path. If you want the language's other benefits — content-addressed code, no builds, no dependency conflicts, abilities, structured refactoring — those are fully open-source and work perfectly for single-machine programs deployed via Docker.

### Spark-Like Distributed Datasets

The Unison team has demonstrated distributed datasets implemented in under 100 lines of Unison, using `Remote` and `Seq` types. You write `Seq.map`, `Seq.filter`, `Seq.reduce` against a distributed dataset, and the framework handles partitioning, shipping, and aggregating across nodes.

### Volturno: Stream Processing

Volturno is Unison's distributed stream-processing library (analogous to Kafka Streams or Flink). Data flows through `KLog` (persistent keyed logs), `KStream` (ephemeral transformation streams), and `Pipeline` (named streaming jobs with persistent state and exactly-once processing). It uses a supervisor/worker model with heartbeats, view changes for fault tolerance, and sharded loglets for parallelism. Volturno runs entirely on the Cloud's `Remote` and `Storage` primitives — it requires the Cloud runtime.

---

## Part IX — Advanced Topics

### Structured Refactoring

In Unison, refactoring is a structured session, not a "break everything and fix the errors" exercise. The old code continues to exist and run while you build the new version alongside it. UCM tracks what needs to be updated and provides a todo list. The codebase is never in a broken state.

### Type-Based Search

Because the codebase stores full type information, you can search by type signature — a feature familiar from Haskell's Hoogle but built into the core tooling.

### Concurrency Primitives

The base library provides `MVar` (mutable variables with blocking semantics), `TVar` and `STM` (software transactional memory for lock-free concurrent data structures), and `Threads` for concurrent execution. The STM system allows composing atomic transactions over shared mutable state.

### HTTP and Networking

The `Http` ability provides HTTP client functionality. Parse a URI, construct a request, and run it through the `Http` handler. Libraries on Unison Share provide higher-level HTTP server and routing support.

### File System Operations

Built-in `FilePath` and `Handle` namespaces in the standard library provide file I/O operations under the `IO` ability.

---

## Part X — Deployment, Operations, and SDLC Without Unison Cloud

The previous sections cover Unison Cloud, but plenty of practical scenarios call for running Unison programs on your own hardware — a development laptop, a bare VPS, an on-prem cluster, or inside a CI/CD pipeline. Unison is an open-source, general-purpose language; the Cloud platform is an optional product built on top of it. Here's how the self-hosted story works.

### Running Programs: Three Modes

There are three ways to execute a Unison program, each suited to a different stage of the lifecycle.

**Interactive execution via `run`.** Inside UCM, type `run myMain` where `myMain : '{IO, Exception} ()`. UCM provides handlers for `IO` and `Exception` and executes the function directly. This is the primary mode during development. You can pass arguments to your program: `run myMain arg1 arg2 arg3`, and inside the program you retrieve them with `getArgs()`, which returns a `[Text]` under the `IO` ability. This mode requires UCM and a live codebase, so it's not suitable for production deployment, but it's ideal for rapid iteration on a laptop.

**Compiled portable bytecode via `compile`.** The command `compile myMain myBinary` produces a file called `myBinary.uc` in the directory where your codebase lives. This `.uc` file is a self-contained bytecode bundle: it includes the entire syntax tree of your program and all its transitive dependencies. There's no linking step and no external library resolution at runtime. Run it from any terminal with `ucm run.compiled myBinary.uc`. This is the primary mechanism for deploying Unison programs outside of UCM — you produce the `.uc` artifact once, copy it to whatever server you like, and execute it there. The only runtime dependency is a compatible version of `ucm` on the target machine. **Important constraint**: the `.uc` file must be run with the same version of `ucm` that compiled it. This is a hard compatibility boundary, so your deployment pipeline needs to pin the UCM version.

**Direct codebase execution.** You can also point UCM at a codebase directory and run a named function from a specific project/branch without entering the interactive prompt: `docker run --rm -v ~/.unison:/codebase unisonlang/unison:latest run hello/main:.program`. This is useful for scripting and CI.

### Dockerized Deployment

The official Docker image `unisonlang/unison` on Docker Hub bundles UCM and can be used in two patterns.

**Pattern 1: Mount a codebase and run from it.** Mount your local codebase into the container at `/codebase` and run a named program. This is convenient for development or testing but means the container depends on having a full codebase available.

```
docker run --rm -v ~/.unison:/codebase unisonlang/unison:latest run myProject/main:.main
```

**Pattern 2: Bake a compiled binary into a Docker image.** This is the production pattern. Compile your program to a `.uc` file locally (or in CI), then build a minimal Docker image that contains only the UCM runtime and your bytecode:

```dockerfile
FROM unisonlang/unison:0.5.29
COPY myService.uc /myService.uc
CMD ["run.compiled", "/myService.uc"]
```

This image is small, self-contained, and can be pushed to any container registry and run on Kubernetes, ECS, Nomad, or a plain `docker run` on a VPS. It's the closest thing Unison has to a traditional "build artifact." You can run it behind a reverse proxy, inside a systemd unit, under a process supervisor — whatever your infrastructure prefers.

The Docker image also exposes ports for the LSP server (5757) and the local codebase browser UI (8080), which can be useful for remote development or codebase inspection.

### Self-Hosted Distributed Execution

The distributed programming features described in Part VIII (hash-based computation shipping, on-the-fly dependency sync) are conceptually part of the language, but the production-grade implementation of the `Remote` ability — the actual compute pool, the networking layer, the service mesh — is provided by Unison Cloud. The Cloud's distributed runtime is not open-source; it's a commercial product.

If you want distributed Unison programs on your own infrastructure, you have two realistic options today:

**Bring Your Own Cloud (BYOC).** As of the 1.0 release, Unison Computing offers a BYOC option where the full Unison Cloud runtime can run on any container-based infrastructure you control — your own AWS account, GCP, Azure, or on-prem Kubernetes. This gives you the `Remote`, `Storage`, `Services`, and all the Cloud abilities, but on your hardware. This is a commercial arrangement; contact Unison Computing for details.

**Roll your own with IO-level networking.** Since Unison is a general-purpose language with full `IO` access, you can write traditional networked programs — HTTP servers, socket listeners, message queue consumers — the same way you would in any other language. You'd use the `Http` ability for client requests, and libraries on Unison Share (like `@unison/http`) for routing and serving. The difference from Unison Cloud is that you're responsible for deploying each service independently, managing serialization at network boundaries (though Unison's content-addressed serialization still helps), and orchestrating your own compute. You lose the "deploy with a function call" magic, but you get a working Unison service on a plain server.

### The Software Development Lifecycle in Unison

Unison's workflow is structurally different from the Git-and-CI pipeline most developers are accustomed to. Here's how the standard SDLC maps onto Unison's tooling.

**Version control.** Unison has its own native version control built into the codebase format. Projects have branches (`branch.create /feature-x`), and you merge branches with `merge /feature-x`. The merge is *semantically aware*: it operates on the content-addressed AST, not on text diffs. Conflicts only arise when two branches genuinely modify the same definition, not from whitespace changes, reordering, or formatting differences. There are no merge conflicts from import order, code style, or file reorganization — those categories of conflict simply don't exist. You do not need Git for Unison code (though the codebase format uses SQLite internally and could in principle be tracked in Git as an opaque blob, there's no real reason to do so).

**Code review and pull requests.** Unison Share provides a contributions system that functions like GitHub PRs. A contributor clones a project, creates a contributor branch (prefixed with their Share handle, like `/@yourHandle/feature`), pushes it, and submits a contribution through the Share UI. The project maintainer can review the diff — which is a semantic diff, not a text diff — and merge it, either through the UI or locally with `merge /@contributor/featureBranch`. Unison Share also supports review comments and per-contribution discussions.

**Releases and versioning.** Unison projects support semantic versioning through a release mechanism. You can cut a release from the Unison Share UI (the recommended approach) or by drafting one in UCM with `release.draft 1.2.0`, which creates a `/releases/drafts/1.2.0` branch. You add a `ReleaseNotes` doc term, push to Share, and publish through the UI. Published releases are immutable snapshots — they don't carry the full branch history, so consumers get a compact dependency. Other projects install a specific release with `lib.install @user/project/releases/1.2.3`.

**Dependency management.** Dependencies live in the `lib` namespace. Install with `lib.install @user/project`. Upgrade with the `upgrade` command, which creates a temporary branch, attempts to migrate your code from the old version to the new one, and lets you resolve any remaining issues before committing with `upgrade.commit`. Because different library versions have different hashes, they coexist in the codebase without conflict — you can have two versions of the same library present simultaneously and migrate at your own pace.

**Testing in CI.** Unison's test caching means that deterministic tests whose dependencies haven't changed simply return cached results. For CI, you'd typically use the Docker image or a UCM binary to run `test` against your project. Transcript files (`.md` files with embedded UCM commands) provide reproducible, scriptable test sessions that can verify the full workflow end-to-end. The `io.test` and `io.test.all` commands handle tests that require IO and therefore can't be cached.

**A practical CI/CD pipeline** for a self-hosted Unison project might look like this: (1) A developer pushes a branch to Unison Share. (2) A CI job pulls the branch, runs `test`, and verifies all tests pass. (3) On merge to `main`, CI runs `compile main myService` to produce a `.uc` artifact. (4) The artifact is baked into a Docker image and pushed to a container registry. (5) The deployment system (Kubernetes, ECS, whatever) rolls out the new image. The compile step is fast because Unison's codebase already has everything typechecked and cached. The Docker image is small because the `.uc` bytecode is lightweight.

**Environment configuration.** For self-hosted deployments, environment variables and command-line arguments are your standard configuration mechanisms. `getArgs()` retrieves CLI arguments; standard `IO` operations can read environment variables. For secrets management, you'd use whatever your infrastructure provides (Vault, AWS Secrets Manager, Kubernetes secrets) and read them at startup through IO, just as in any other language.

### What Unison Doesn't (Yet) Have for Self-Hosted Operations

It's worth being honest about the gaps. Unison currently lacks a native compilation target that produces standalone binaries without a UCM runtime dependency — the `.uc` format is interpreted bytecode, not machine code. The runtime has seen significant optimization work (especially around the 1.0 release), but it's still an interpreter, not a JIT or AOT compiler. For compute-intensive workloads, this matters. C FFI support is on the roadmap but not yet shipped, which limits interoperability with existing C libraries.

There's also no built-in observability story (structured logging, metrics, tracing) outside of what Unison Cloud provides. For self-hosted services, you'd need to build or integrate these yourself using IO-level libraries. The ecosystem of third-party libraries is growing but still small compared to mainstream languages. And while the language itself is 1.0-stable, the tooling around self-hosted production deployments (health checks, graceful shutdown, signal handling, log rotation) is still an area where you'll need to bring your own solutions.

---

## Part XI — Academic Foundations, Related Languages, and Further Reading

### Theoretical Underpinnings

Unison doesn't exist in a vacuum. Its design draws on specific, identifiable research that's worth understanding if you want to master the language deeply.

**The type system** implements the bidirectional typechecking algorithm from Dunfield and Krishnaswami's "Complete and Easy Bidirectional Typechecking for Higher-Rank Polymorphism" (2013). This is not a loose inspiration — the Unison typechecker is formally an implementation of this system. The follow-up paper (2016) extends it with existentials and indexed types and is noted on Unison's bibliography as likely to be implemented in a future version.

**The ability system** is based on the Frank language by Lindley, McBride, and McLaughlin, described in their 2017 paper "Do Be Do Be Do." Frank is a research language that treats effects as first-class citizens in the type system, and Unison's abilities are a direct adaptation of Frank's approach, with some divergences in syntax and semantics. Understanding the Frank paper gives you deep insight into how ability handlers work and why continuations appear in handler patterns.

**The broader algebraic effects tradition** that Unison draws from includes Plotkin and Pretnar's foundational work on handlers of algebraic effects (ESOP 2009, LMCS 2013), Bauer and Pretnar's Eff language (2012), Pretnar's tutorial on algebraic effects and handlers (2015), Kammar, Lindley and Oury's "Handlers in Action" (ICFP 2013), and Daan Leijen's work on the Koka language with row-polymorphic effect types. The community-maintained effects bibliography on GitHub is an invaluable resource for going deeper.

**Content-addressed code** — the core idea that definitions are identified by hashes of their syntax trees — is Unison's most distinctive innovation. Unlike the type system and ability system, which build on published research, content-addressing as applied to a programming language is primarily documented through Unison's own materials (the "Big Idea" page, Paul Chiusano's talks) rather than academic papers. The closest academic antecedent is the broader tradition of content-addressable storage in systems like Git and IPFS, applied at the granularity of individual definitions rather than files.

### Related Languages

Unison was influenced primarily by Haskell (pure functional programming, type inference, algebraic data types), Erlang (distributed execution, fault tolerance, the actor model), and the Frank research language (algebraic effects). Additional influences include Smalltalk (image-based persistence and the idea of a "live" development environment), Scala (where the founders spent years and wrote *Functional Programming in Scala*), and Elm (developer experience focus).

Several other languages occupy the same design space of algebraic effects and are worth studying in comparison: Eff (the original research language for algebraic effects, by Bauer and Pretnar), Koka (Daan Leijen's language with row-polymorphic effect types), OCaml 5 / Multicore OCaml (which brought algebraic effects into a production language), Idris 2 (dependently-typed with algebraic effects), and Effekt (a research language centered on effect handlers). None of these share Unison's content-addressing or codebase-as-database approach, but they all implement variants of the same algebraic effects theory that underlies Unison's abilities.

### Books by Unison's Creators

No dedicated Unison book exists yet (the "Unison in Practice" book on Amazon has been flagged by the community as unreliable — its code samples appear AI-generated and don't produce valid Unison). The primary learning resources are the official documentation and the exercises on Exercism.

However, the cofounders wrote **Functional Programming in Scala** (1st ed., Manning, 2014) by Paul Chiusano and Rúnar Bjarnason, widely regarded as one of the best FP books ever written. Many of the ideas explored there — pure functional IO, algebraic design, composable effect management — directly fed into Unison's design. A second edition by Pilquist, Chiusano, and Bjarnason was published in 2023, updated for Scala 3.

### Key Talks (with Video Links)

The Strange Loop 2019 talk by Paul Chiusano ("Unison: a new distributed programming language," approximately 40 minutes) is the single best introduction. It covers the premise that distributed systems should be expressible via a single program, walks through the content-addressing idea, and demonstrates the UCM workflow live. The Scale By the Bay 2019 talk covers refactoring in depth. Rúnar Bjarnason's Lambda World Seattle 2018 talk provides a complementary perspective focused on the codebase model and distributed programming.

### Community Articles Worth Reading

Several in-depth community articles provide perspectives the official docs don't cover. Renato Athaydes' "A look at Unison: a revolutionary programming language" (January 2023) is a detailed hands-on review. The LWN.net article "Programming in Unison" (June 2024) covers the language's history since 2013 and its relationship to Smalltalk-style image persistence. Adam Warski's three-part "Trying out Unison" series at SoftwareMill digs into abilities from a practical standpoint. Dave Thomas (pragdave) wrote "Abilities: a New Way to Inject Behavior and State" exploring the ability system's implications. And there's an excellent unofficial abilities tutorial by atacratic as a GitHub gist that fills some gaps the official docs leave.

### Practice Resources

The Exercism Unison track offers 53 exercises with automatic analysis and optional mentoring. The official Wordle clone learning lab walks through building a complete console game. LearnUnison.com and UnisonProgramming.com aggregate community video content. The side-by-side guides on the Unison docs site (for Java, Python, and Scala developers) are useful for mapping familiar concepts to their Unison equivalents.

---

## Part XII — Architecture for a Self-Hosted Unison Ops Platform

This section describes the architecture for building a self-hosted platform that provides ability handlers for Unison programs. It details what handlers are needed, what can be written in Unison versus what requires an external runtime, and why BEAM (Erlang/OTP via Elixir) is a strong candidate for the outer shell.

### What You're Building

You need to implement handlers for the core Unison Cloud abilities so programs can run on your own infrastructure. The core ones are:

`Remote` — fork a computation to a different node, await its result, get the current time, generate random values. This is the heart of the system. It requires shipping serialized Unison bytecode (identified by hash) from one node to another, syncing any missing dependencies by hash, executing the computation, and returning the result.

`Storage` / `Transaction` — typed durable key-value storage with transactional semantics. `OrderedTable` needs sorted key-value access with range queries. `Cell` stores a single value. `Table` is a basic key-value lookup. `Blobs` stores binary data by key with prefix listing. Transactions must be atomic across multiple tables within a database.

`Services` — deploy a function as a named, versioned service identified by its content hash, then call it from other nodes. This is a typed RPC registry.

`Config` — encrypted key-value store for secrets, scoped to an Environment. `Scratch` — ephemeral in-memory cache bound to a specific compute location. `Log` — structured logging. Plus the `Cloud` ability itself, which orchestrates `Environment` and `Database` creation, `deploy`, and `submit`.

### The Bootstrapping Problem: What Can Be Written in Unison?

The entire coordination logic — the service registry, the hash-sync protocol, dependency resolution, deployment orchestration, environment/database management, routing of `Services.call` — is ordinary application code. Unison is perfectly capable of all of this, and Unison Cloud's own orchestration layer is itself written entirely in Unison.

You can also write the storage abstraction layer in Unison — the code that translates `OrderedTable.write.tx` into calls to an external database. Using the `Http` ability you can talk to a FoundationDB HTTP API, a PostgreSQL wire protocol library, or an S3-compatible blob store. The `IO` ability gives you sockets, file system access, and environment variables.

However, there is a bootstrapping paradox at the lowest layer. You're implementing the handler for the `Remote` ability, but to run Unison code on a remote node, you need `Remote` to already be working. You can't ship a computation using `Remote.fork` if the handler for `Remote.fork` is itself the thing you're building.

Three things must happen below the Unison abstraction level. First, a process must listen for incoming bytecode on the network — something has to start before any Unison code runs. Second, when bytecode arrives, the node must invoke the Unison interpreter to execute it. There is no `eval` or `loadAndRun` function in the Unison standard library that accepts raw bytecode — the interpreter is not self-hosting. Third, the code cache must be managed at the bytecode level, storing raw serialized AST fragments that only the external interpreter can turn into running computations.

### The Two-Layer Architecture

The realistic design is a layered system. A thin non-Unison shell handles the three things Unison can't do for itself, and everything above that shell is written in Unison.

**The outer shell** (Elixir/Erlang on BEAM) does exactly three things: (1) starts and supervises the Unison interpreter process on each node, (2) accepts incoming bytecode from the network and feeds it to the interpreter, and (3) joins the cluster and maintains node-to-node connectivity. On BEAM, this is a small OTP application — a few hundred lines. The BEAM node boots, connects to the cluster, starts a UCM subprocess, and listens for incoming work. When work arrives (bytecode + hash manifest), it checks the local ETS-based cache, requests missing hashes from peer nodes via BEAM distribution, writes them to the cache, and invokes the interpreter.

**Everything above that** is Unison. The coordinator logic that decides which node to route a computation to, the `Storage` handler that talks to FoundationDB or PostgreSQL, the `Services` registry, the `Config` encryption, `Environment` management, `Log`, `Scratch` — all Unison, written as ability handlers running as a long-lived `IO` program on each node.

The outer shell is small, dumb, and stable — the equivalent of systemd starting your application. You'd write it once and rarely touch it. The Unison layer is where all the complexity and evolution happens. If the Unison team ever adds a `loadAndExecute : Bytes ->{IO} a` primitive, the outer shell could shrink to almost nothing. Until then, the thin BEAM shell is the pragmatic answer.

### Why BEAM is the Strongest Candidate

The mappings between Unison Cloud's abstractions and BEAM primitives are remarkably tight.

`Remote.fork` maps to BEAM's `spawn(Node, Fun)` — spawning a lightweight process on a remote node is a single function call. BEAM processes cost a few hundred bytes each, are preemptively scheduled and independently garbage-collected. You can have millions running simultaneously.

Unison's Daemons (long-running processes automatically restarted on crash) map directly to OTP supervision trees — the core design pattern of Erlang, refined over 35+ years of telecom-grade production use. You'd implement `Daemon` as a supervised `gen_server` under an OTP supervisor with a `:permanent` restart strategy.

The ~100µs service call latency that BYOC advertises maps to BEAM's native distribution protocol, which operates at similar latencies within a data center. Messages between processes on different nodes use the same `send` primitive as local messages — distribution is transparent.

Node discovery and clustering are built in. BEAM nodes discover each other through cookie-based authentication and DNS or `libcluster`. You don't need etcd, Consul, or NATS — it's in the runtime. This eliminates an entire infrastructure layer.

ETS (Erlang Term Storage) is perfect for the hash-keyed code cache — concurrent reads with sub-microsecond lookups. Mnesia (BEAM's built-in distributed database) could serve as a v1 storage backend providing transactions, ordered sets, and node-to-node replication, or you'd back it with FoundationDB or PostgreSQL for production scale. ETS also maps perfectly to `Scratch` (ephemeral in-memory cache).

### Storage Backend Choices

For production, FoundationDB is the strongest match for the storage abilities. It provides ordered key-value storage with strict serializable ACID transactions across arbitrary key ranges — exactly what `OrderedTable` and `Transaction` need. You'd implement `OrderedTable` as a key-prefix namespace within FoundationDB, `Cell` as a single key, `Table` as hash-indexed lookups, and `Blobs` as either FoundationDB values (small blobs) or MinIO/S3-compatible storage (large ones). FoundationDB is open-source (Apache 2.0), battle-tested (Apple runs iCloud on it), and self-hostable.

For initial development, Mnesia (zero additional infrastructure, already part of OTP) or PostgreSQL (excellent transaction support, widely deployed) can serve as stepping stones.

### Recommended Build Sequence

Phase 1: Implement a `Storage` handler backed by FoundationDB (or Mnesia) that handles `OrderedTable`, `Cell`, and `Transaction` on a single node. This is immediately useful even without distribution.

Phase 2: Implement the hash cache and dependency-sync protocol between two BEAM nodes using ETS and BEAM distribution.

Phase 3: Implement a basic `Remote` handler that forks a computation to another node and awaits its result, with UCM as a managed subprocess.

Phase 4: Implement `Services` (deploy and call via a distributed registry — Elixir's `Horde` library provides distributed supervisors and registries that map directly).

Phase 5: Add `Config`, `Blobs`, `Scratch`, `Log` — these are comparatively simple once the core infrastructure exists.

The hardest engineering challenge throughout is understanding the exact serialization format UCM uses for bytecode and the interface ability handlers need to present. The Haskell source in the GitHub repo (`unison-runtime`) is the primary reference.

---

## Reference URLs Consulted

### Official Documentation
1. https://www.unison-lang.org/ — Main website and landing page
2. https://www.unison-lang.org/docs/ — Documentation hub and "at a glance" overview
3. https://www.unison-lang.org/docs/the-big-idea/ — Content-addressed code explained
4. https://www.unison-lang.org/docs/quickstart/ — Installation and quickstart guide
5. https://www.unison-lang.org/docs/tour/ — Tour of the Unison workflow (6 parts)
6. https://www.unison-lang.org/docs/at-a-glance/ — Syntax overview with code snippets
7. https://www.unison-lang.org/docs/fundamentals/values-and-functions/terms — Defining terms, tuples, basic types
8. https://www.unison-lang.org/docs/fundamentals/values-and-functions/common-collection-types — Lists, Maps, Sets
9. https://www.unison-lang.org/docs/fundamentals/values-and-functions/functions — Functions and lambdas
10. https://www.unison-lang.org/docs/fundamentals/values-and-functions/reading-type-signatures — Type signatures
11. https://www.unison-lang.org/docs/fundamentals/values-and-functions/defining-operators — Custom operators
12. https://www.unison-lang.org/docs/fundamentals/values-and-functions/function-application-operators — Pipe operators
13. https://www.unison-lang.org/docs/fundamentals/values-and-functions/delayed-computations — Thunks and `do`
14. https://www.unison-lang.org/docs/fundamentals/control-flow/if-then-and-else — Conditionals
15. https://www.unison-lang.org/docs/fundamentals/control-flow/pattern-matching — Pattern matching (parts 1 & 2)
16. https://www.unison-lang.org/docs/fundamentals/control-flow/looping — Recursion and looping
17. https://www.unison-lang.org/docs/fundamentals/control-flow/exception-handling — Error handling with data types
18. https://www.unison-lang.org/docs/fundamentals/data-types/unique-and-structural-types — Type system
19. https://www.unison-lang.org/docs/fundamentals/data-types/record-types — Record syntax
20. https://www.unison-lang.org/docs/fundamentals/abilities — Abilities mental model
21. https://www.unison-lang.org/docs/fundamentals/abilities/using-abilities-pt1 — Using abilities (part 1)
22. https://www.unison-lang.org/docs/fundamentals/abilities/using-abilities-pt2 — Using abilities (part 2)
23. https://www.unison-lang.org/docs/fundamentals/abilities/error-handling — Error handling with abilities
24. https://www.unison-lang.org/docs/fundamentals/abilities/writing-abilities — Writing custom abilities
25. https://www.unison-lang.org/docs/fundamentals/abilities/for-monadically-inclined — Abilities vs. monads
26. https://www.unison-lang.org/docs/fundamentals/abilities/faqs — Ability FAQs
27. https://www.unison-lang.org/docs/usage-topics/testing — Testing guide
28. https://www.unison-lang.org/docs/usage-topics/documentation — Documentation format
29. https://www.unison-lang.org/docs/usage-topics/running-programs — Running programs
30. https://www.unison-lang.org/docs/usage-topics/profiling — Profiling
31. https://www.unison-lang.org/docs/usage-topics/docker — Docker usage
32. https://www.unison-lang.org/docs/usage-topics/editor-setup — Editor configuration
33. https://www.unison-lang.org/docs/usage-topics/mcp-setup — MCP (AI) setup
34. https://www.unison-lang.org/docs/usage-topics/general-faqs — General FAQs
35. https://www.unison-lang.org/docs/usage-topics/bibliography — Academic bibliography
36. https://www.unison-lang.org/docs/tooling/transcripts — Transcript files
37. https://www.unison-lang.org/docs/tooling/project-workflows — Project workflows
38. https://www.unison-lang.org/docs/tooling/unison-share — Unison Share hosting
39. https://www.unison-lang.org/docs/tooling/ucm-desktop — Desktop app
40. https://www.unison-lang.org/docs/tooling/ucm-env-vars — Environment variables
41. https://www.unison-lang.org/docs/tooling/author-license — Author and license metadata
42. https://www.unison-lang.org/docs/ucm-commands — UCM command reference
43. https://www.unison-lang.org/docs/projects — Projects quickstart

### Language Reference
44. https://www.unison-lang.org/docs/language-reference/top-level-declaration — Top-level declarations
45. https://www.unison-lang.org/docs/language-reference/term-declarations — Term declarations
46. https://www.unison-lang.org/docs/language-reference/type-signatures — Type signatures
47. https://www.unison-lang.org/docs/language-reference/ability-declaration — Ability declarations
48. https://www.unison-lang.org/docs/language-reference/user-defined-data-types — Data types
49. https://www.unison-lang.org/docs/language-reference/structural-types — Structural types
50. https://www.unison-lang.org/docs/language-reference/unique-types — Unique types
51. https://www.unison-lang.org/docs/language-reference/record-type — Record types
52. https://www.unison-lang.org/docs/language-reference/expressions — Expressions
53. https://www.unison-lang.org/docs/language-reference/literals — Literals
54. https://www.unison-lang.org/docs/language-reference/blocks-and-statements — Blocks
55. https://www.unison-lang.org/docs/language-reference/match-expressions-and-pattern-matching — Pattern matching
56. https://www.unison-lang.org/docs/language-reference/ability-patterns — Ability patterns
57. https://www.unison-lang.org/docs/language-reference/types — Type system reference
58. https://www.unison-lang.org/docs/language-reference/polymorphic-types — Polymorphism
59. https://www.unison-lang.org/docs/language-reference/function-types — Function types
60. https://www.unison-lang.org/docs/language-reference/built-in-types — Built-in types
61. https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers — Abilities reference
62. https://www.unison-lang.org/docs/language-reference/ability-handlers — Handler syntax
63. https://www.unison-lang.org/docs/language-reference/use-clauses — Use clauses
64. https://www.unison-lang.org/docs/language-reference/delayed-computations — Delayed computations ref
65. https://www.unison-lang.org/docs/language-reference/hashes — Hash reference

### Side-by-Side Guides
66. https://www.unison-lang.org/compare-lang/unison-for-java-devs/ — Unison for Java developers
67. https://www.unison-lang.org/compare-lang/unison-for-python-devs/ — Unison for Python developers
68. https://www.unison-lang.org/compare-lang/unison-for-scala-devs/ — Unison for Scala developers

### Learning Labs
69. https://www.unison-lang.org/docs/labs/wordle/docs/intro — Wordle clone lab
70. https://exercism.org/tracks/unison — Exercism Unison track (53 exercises)

### Unison Cloud Platform
71. https://www.unison.cloud/ — Cloud platform home
72. https://www.unison.cloud/docs/core-concepts/ — Core concepts
73. https://www.unison.cloud/docs/local-development/ — Local development
74. https://www.unison.cloud/docs/example-apps/ — Example applications
75. https://www.unison.cloud/docs/custom-domain-support/ — Custom domains
76. https://www.unison.cloud/docs/resources/ — Useful libraries
77. https://www.unison.cloud/docs/storage-solutions/ — Storage types cheat sheet
78. https://www.unison.cloud/docs/storage-schema-management/ — Schema migration FAQs
79. https://www.unison.cloud/docs/general-storage-faqs/ — Durable storage FAQs
80. https://www.unison.cloud/docs/local-development-faqs/ — Local development FAQs
81. https://www.unison.cloud/docs/tutorials/http-service-tutorial/ — HTTP service tutorial
82. https://www.unison.cloud/docs/tutorials/slackbot-tutorial/ — Slackbot tutorial
83. https://www.unison.cloud/docs/tutorials/schema-modeling/ — OrderedTable schema modeling
84. https://www.unison.cloud/learn/ — Interactive learning modules
85. https://www.unison.cloud/learn/http-hello-world/ — Hello World deployment
86. https://www.unison.cloud/learn/native-services/ — Native service calls
87. https://www.unison.cloud/learn/microblogging/ — Microblog CRUD app
88. https://www.unison.cloud/learn/auth/ — Authentication with OAuth2
89. https://www.unison.cloud/pricing — Pricing (Free tier: 5 services, 50MB storage, 5k req/mo)
90. https://www.unison.cloud/byoc — Bring Your Own Cloud

### Ecosystem and Community
91. https://share.unison-lang.org — Unison Share (library hosting and code browsing)
92. https://github.com/unisonweb/unison — GitHub repository
93. https://unison-lang.org/discord — Community Discord
94. https://www.unison-lang.org/blog — Official blog
95. https://www.unison-lang.org/roadmap — Development roadmap
96. https://www.unison-lang.org/unison-computing/ — About Unison Computing (public benefit corp)
97. https://lwn.net/Articles/978955/ — LWN.net deep-dive article on Unison
98. https://unisonprogramming.com/ — Community resource aggregator
99. https://www.youtube.com/@unisonlanguage — YouTube channel

### Deployment, Operations, and SDLC
100. https://www.unison-lang.org/docs/usage-topics/running-programs — Running programs (run, compile, run.compiled)
101. https://www.unison-lang.org/docs/usage-topics/docker — Running Unison in Docker
102. https://hub.docker.com/r/unisonlang/unison — Official Docker image
103. https://www.unison-lang.org/docs/tooling/project-workflows — Project workflows (branching, merging, releases, PRs)
104. https://www.unison-lang.org/docs/usage-topics/workflow-how-tos/update-code — Updating code and dependencies
105. https://www.unison-lang.org/docs/usage-topics/resetting-codebase-state — Resetting codebase state
106. https://www.unison-lang.org/docs/tooling/projects-codebase-organization — Codebase organization
107. https://www.unison-lang.org/unison-1-0/ — Unison 1.0 announcement (BYOC, roadmap, timeline)
108. https://www.unison.cloud/our-approach/ — Unison Cloud's technical approach and requirements
109. https://www.unison.cloud/byoc — Bring Your Own Cloud details
110. https://news.ycombinator.com/item?id=39292527 — HN discussion on self-hosting Unison
111. https://dev.to/zelenya/unison-from-0-to-cloud-54g1 — Community walkthrough: Unison from zero to Cloud

### Cloud Internals and Architecture
112. https://www.unison-lang.org/blog/visualizing-remote/ — Visualizing remote computations (RemoteVis library)
113. https://www.unison-lang.org/blog/volturno-design/ — Volturno distributed stream-processing design
114. https://www.unison-lang.org/blog/unison-share-is-open-source/ — Unison Share open-sourced (May 2024)
115. https://share.unison-lang.org/@systemfw/volturno — Volturno library on Unison Share
116. https://www.unison.cloud/pricing — Full pricing breakdown (Cloud and BYOC)

### Talks (with Video Links)
117. https://youtu.be/gCWtkvDQ2ZI — Paul Chiusano, Strange Loop 2019 (best intro talk)
118. https://slides.com/pchiusano/unison-strange-loop-2019 — Slides for Strange Loop 2019
119. https://www.youtube.com/watch?v=IvENPRGJMRk — Paul Chiusano, Scale By the Bay 2019
120. https://www.youtube.com/watch?v=rp_Eild1aq8 — Rúnar Bjarnason, Lambda World Seattle 2018
121. http://blog.higher-order.com/assets/LambdaWorldSeattle.pdf — Slides for Lambda World 2018
122. https://slides.com/pchiusano/unison-scala-world-2017 — Paul Chiusano, Scala World 2017 slides
123. https://www.unison-lang.org/talks/ — Official talks page

### Foundational Research Papers
124. https://arxiv.org/abs/1306.6032 — Dunfield & Krishnaswami, "Complete and Easy Bidirectional Typechecking" (2013)
125. https://arxiv.org/abs/1601.05106 — Dunfield & Krishnaswami, extended version with existentials (2016)
126. https://arxiv.org/abs/1611.09259 — Lindley, McBride & McLaughlin, "Do Be Do Be Do" (Frank paper, 2017)
127. https://arxiv.org/abs/1203.1539 — Bauer & Pretnar, "Programming with Algebraic Effects and Handlers" (Eff, 2012)
128. https://www.eff-lang.org/handlers-tutorial.pdf — Pretnar, "An Introduction to Algebraic Effects and Handlers" (2015)
129. https://doi.org/10.1007/978-3-642-00590-9_7 — Plotkin & Pretnar, "Handlers of Algebraic Effects" (ESOP 2009)
130. https://doi.org/10.2168/LMCS-9(4:23)2013 — Plotkin & Pretnar, "Handling Algebraic Effects" (LMCS 2013)
131. https://doi.org/10.1145/2500365.2500590 — Kammar, Lindley & Oury, "Handlers in Action" (ICFP 2013)
132. https://www.microsoft.com/en-us/research/publication/algebraic-effects-for-functional-programming/ — Leijen, "Algebraic Effects for Functional Programming" (Koka, 2017)
133. https://kcsrk.info/papers/effects_dagstuhl18.pdf — Dagstuhl 2018, "Algebraic Effect Handlers Go Mainstream"
134. https://github.com/yallop/effects-bibliography — Community effects bibliography (comprehensive)
135. https://www.unison-lang.org/docs/usage-topics/bibliography/ — Unison's own annotated bibliography

### Related Languages
136. https://www.eff-lang.org/ — Eff language (Bauer & Pretnar)
137. https://koka-lang.github.io/koka/doc/index.html — Koka language (Daan Leijen)
138. https://effekt-lang.org/ — Effekt research language
139. https://www.idris-lang.org/ — Idris 2
140. https://github.com/ocaml-multicore/ocaml-multicore — OCaml 5 with algebraic effects

### Books by Unison's Creators
141. https://www.manning.com/books/functional-programming-in-scala — FP in Scala, 1st ed. (Chiusano & Bjarnason, 2014)
142. https://www.manning.com/books/functional-programming-in-scala-second-edition — FP in Scala, 2nd ed. (2023)

### Community Articles and Third-Party Resources
143. https://renato.athaydes.com/posts/unison-revolution.html — "A look at Unison: a revolutionary programming language" (Jan 2023)
144. https://softwaremill.com/trying-out-unison-part-3-effects-through-abilities/ — Adam Warski, "Trying out Unison" series
145. https://pragdave.me/discover/unison/2023-03-11-abilities/ — Dave Thomas, "Abilities: a New Way to Inject Behavior and State"
146. https://gist.github.com/atacratic/7a91901d5535391910a2d34a2636a93c — Unofficial abilities tutorial (atacratic)
147. https://interjectedfuture.com/algebraic-handler-lookup-in-koka-eff-ocaml-and-unison/ — Algebraic handler lookup comparison
148. https://devth.com/unison-talk-at-strangeloop — Notes on the Strange Loop talk
149. http://blog.higher-order.com — Rúnar Bjarnason's blog
150. https://learnunison.com/ — LearnUnison.com community site
151. https://news.ycombinator.com/item?id=34307552 — HN discussion thread (2023)
152. https://fosstodon.org/@unison — Mastodon
153. https://bsky.app/profile/unison-lang.org — Bluesky
