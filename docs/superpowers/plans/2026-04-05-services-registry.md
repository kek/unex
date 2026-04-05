# Services Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy compiled Unison programs as named services and call them by name from any node in the cluster — a typed RPC registry where deploy-same-code-get-same-hash, and stable names point to the latest deployment.

**Architecture:** A `Services.Registry` GenServer on each node stores name→hash mappings in ETS. `Services.deploy/2` compiles Unison source, caches the bytecode in HashCache, and registers the name→hash mapping. `Services.call/2` looks up the hash by name (checking local registry then peers), then delegates to `Remote.execute/2`. HTTP endpoints at `/services/*` make services accessible to Unison programs via the existing HTTP pattern.

**Tech Stack:** Elixir 1.19 / OTP 28, ETS (registry storage), existing Uniops modules (HashCache, Remote, Compiler, Workspace)

---

## Scope Note

This is Plan 5 of 6. It adds the service abstraction on top of Plans 1-4. What it covers:
- Service registry (name → bytecode hash mapping)
- Deploy (compile + cache + register)
- Call by name (lookup + remote execute)
- Cross-node service discovery (ask peers for unknown names)
- HTTP API for services

What it does **not** cover:
- Service versioning history (only latest deployment per name)
- Health checks / automatic restarts (future Daemon abstraction)
- Load balancing across replicas

## Prerequisites

- Plans 1-4 completed

## File Structure

```
lib/
  uniops/
    services/
      registry.ex                   # GenServer + ETS: name→hash mappings, cross-node lookup
    services.ex                     # Public API: deploy, call, list, undeploy
    api/
      router.ex                     # Modify: add /services routes
      services_controller.ex        # HTTP handlers for service endpoints
test/
  uniops/
    services/
      registry_test.exs             # Registry unit tests
    services_test.exs               # Deploy + call tests (local)
  integration/
    services_cluster_test.exs       # Multi-node: deploy on A, call from B
```

---

### Task 1: Services Registry

**Files:**
- Create: `lib/uniops/services/registry.ex`
- Create: `test/uniops/services/registry_test.exs`

The Registry is a GenServer owning an ETS table that maps service names to deployment info.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/services/registry_test.exs`:

```elixir
defmodule Uniops.Services.RegistryTest do
  use ExUnit.Case, async: false

  alias Uniops.Services.Registry

  setup do
    reg = start_supervised!({Registry, name: :test_registry})
    %{reg: reg}
  end

  describe "register/4 and lookup/2" do
    test "registers a service and looks it up by name", %{reg: reg} do
      assert :ok = Registry.register(reg, "greeter", "abc123", node())
      assert {:ok, info} = Registry.lookup(reg, "greeter")
      assert info.hash == "abc123"
      assert info.name == "greeter"
      assert info.node == node()
    end

    test "returns :not_found for unknown service", %{reg: reg} do
      assert :not_found = Registry.lookup(reg, "nope")
    end

    test "redeploying updates the hash", %{reg: reg} do
      Registry.register(reg, "svc", "hash1", node())
      Registry.register(reg, "svc", "hash2", node())
      assert {:ok, %{hash: "hash2"}} = Registry.lookup(reg, "svc")
    end
  end

  describe "list/1" do
    test "returns all registered services", %{reg: reg} do
      Registry.register(reg, "a", "h1", node())
      Registry.register(reg, "b", "h2", node())
      services = Registry.list(reg)
      names = Enum.map(services, & &1.name) |> Enum.sort()
      assert names == ["a", "b"]
    end
  end

  describe "unregister/2" do
    test "removes a service", %{reg: reg} do
      Registry.register(reg, "temp", "h1", node())
      assert :ok = Registry.unregister(reg, "temp")
      assert :not_found = Registry.lookup(reg, "temp")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/services/registry_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the Registry**

Create `lib/uniops/services/registry.ex`:

```elixir
defmodule Uniops.Services.Registry do
  @moduledoc """
  GenServer-backed service registry. Maps service names to bytecode hashes
  and deployment metadata. Supports cross-node lookups via the ask-peers pattern.
  """

  use GenServer

  defmodule Entry do
    @moduledoc false
    defstruct [:name, :hash, :node, :deployed_at]
  end

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers a service name → bytecode hash mapping."
  def register(server \\ __MODULE__, name, hash, deploy_node) do
    GenServer.call(server, {:register, name, hash, deploy_node})
  end

  @doc "Looks up a service by name. Returns `{:ok, %Entry{}}` or `:not_found`."
  def lookup(server \\ __MODULE__, name) do
    GenServer.call(server, {:lookup, name})
  end

  @doc "Looks up locally first, then asks peers. Returns `{:ok, %Entry{}}` or `:not_found`."
  def resolve(server \\ __MODULE__, name) do
    GenServer.call(server, {:resolve, name}, 10_000)
  end

  @doc "Returns all registered services as a list of `%Entry{}`."
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc "Removes a service by name."
  def unregister(server \\ __MODULE__, name) do
    GenServer.call(server, {:unregister, name})
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(table_name, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, name, hash, deploy_node}, _from, state) do
    entry = %Entry{
      name: name,
      hash: hash,
      node: deploy_node,
      deployed_at: DateTime.utc_now()
    }

    :ets.insert(state.table, {name, entry})
    {:reply, :ok, state}
  end

  def handle_call({:lookup, name}, _from, state) do
    result =
      case :ets.lookup(state.table, name) do
        [{^name, entry}] -> {:ok, entry}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  def handle_call({:resolve, name}, _from, state) do
    result =
      case :ets.lookup(state.table, name) do
        [{^name, entry}] ->
          {:ok, entry}

        [] ->
          ask_peers_for_service(name)
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, state) do
    services = :ets.select(state.table, [{{:_, :"$1"}, [], [:"$1"]}])
    {:reply, services, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(state.table, name)
    {:reply, :ok, state}
  end

  defp ask_peers_for_service(name) do
    Enum.find_value(Node.list(), :not_found, fn peer ->
      try do
        case GenServer.call({__MODULE__, peer}, {:lookup, name}, 5_000) do
          {:ok, _entry} = found -> found
          :not_found -> nil
        end
      catch
        :exit, _ -> nil
      end
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/uniops/services/registry_test.exs`
Expected: 5 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add services registry with name→hash mappings and cross-node lookup"
jj new
```

---

### Task 2: Services Public API

**Files:**
- Create: `lib/uniops/services.ex`
- Create: `test/uniops/services_test.exs`
- Modify: `lib/uniops/application.ex`

The public API composes Registry + HashCache + Remote.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/services_test.exs`:

```elixir
defmodule Uniops.ServicesTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  describe "deploy/2 and call/2" do
    test "deploys Unison source as a named service and calls it" do
      source = "main : '{IO, Exception} ()\nmain = do printLine \"svc-hello\""

      assert {:ok, info} = Uniops.Services.deploy("greeter", source)
      assert info.name == "greeter"
      assert is_binary(info.hash)
      assert info.node == node()

      assert {:ok, result} = Uniops.Services.call("greeter")
      assert result.stdout =~ "svc-hello"
    end

    test "redeploying updates the service" do
      source_v1 = "main : '{IO, Exception} ()\nmain = do printLine \"v1\""
      source_v2 = "main : '{IO, Exception} ()\nmain = do printLine \"v2\""

      {:ok, info1} = Uniops.Services.deploy("versioned", source_v1)
      {:ok, info2} = Uniops.Services.deploy("versioned", source_v2)
      assert info1.hash != info2.hash

      {:ok, result} = Uniops.Services.call("versioned")
      assert result.stdout =~ "v2"
    end

    test "calling unknown service returns error" do
      assert {:error, :not_found} = Uniops.Services.call("nonexistent")
    end
  end

  describe "list/0" do
    test "returns deployed services" do
      source = "main : '{IO, Exception} ()\nmain = do printLine \"listed\""
      Uniops.Services.deploy("listed_svc", source)

      services = Uniops.Services.list()
      names = Enum.map(services, & &1.name)
      assert "listed_svc" in names
    end
  end

  describe "undeploy/1" do
    test "removes a service" do
      source = "main : '{IO, Exception} ()\nmain = do printLine \"bye\""
      Uniops.Services.deploy("temp_svc", source)
      assert :ok = Uniops.Services.undeploy("temp_svc")
      assert {:error, :not_found} = Uniops.Services.call("temp_svc")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/services_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the Services module**

Create `lib/uniops/services.ex`:

```elixir
defmodule Uniops.Services do
  @moduledoc """
  Deploy compiled Unison programs as named services and call them by name.

  A service is a named pointer to a bytecode hash in the HashCache.
  Deploying compiles source, caches the bytecode, and registers the name.
  Calling looks up the hash by name and delegates to Remote.execute.
  """

  alias Uniops.Services.Registry
  alias Uniops.Cluster.HashCache

  @doc """
  Deploys Unison source code as a named service.

  Compiles the source to .uc bytecode, caches it in HashCache,
  and registers the name → hash mapping in the Registry.

  Returns `{:ok, %Registry.Entry{}}` or `{:error, reason}`.
  """
  def deploy(name, source, opts \\ []) do
    entry_point = Keyword.get(opts, :entry, "main")

    with {:ok, uc_bytes} <- compile_source(source, entry_point) do
      hash = HashCache.put(uc_bytes)
      :ok = Registry.register(name, hash, node())
      {:ok, %Registry.Entry{name: name, hash: hash, node: node(), deployed_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Calls a service by name. Resolves the name to a bytecode hash
  (checking local registry then peers) and executes via Remote.

  Options:
    - `:timeout` — execution timeout (default: 60_000)
    - `:args` — arguments to pass to the program

  Returns `{:ok, %Runner.Result{}}` or `{:error, reason}`.
  """
  def call(name, opts \\ []) do
    case Registry.resolve(name) do
      {:ok, entry} ->
        Uniops.Remote.execute(entry.hash, opts)

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc "Lists all known services."
  def list do
    Registry.list()
  end

  @doc "Removes a service by name."
  def undeploy(name) do
    Registry.unregister(name)
  end

  defp compile_source(source, entry_point) do
    dir = Path.join(System.tmp_dir!(), "uniops_svc_#{System.unique_integer([:positive])}")

    with {:ok, workspace} <- Uniops.Workspace.create(dir),
         {:ok, file_path} <- Uniops.Workspace.write_source(workspace, "service.u", source),
         {:ok, uc_path} <- Uniops.Compiler.compile(workspace, file_path, entry_point, "service") do
      uc_bytes = File.read!(uc_path)
      Uniops.Workspace.destroy(workspace)
      {:ok, uc_bytes}
    else
      {:error, _} = err ->
        File.rm_rf(dir)
        err
    end
  end
end
```

- [ ] **Step 4: Add Registry to supervision tree**

Update `lib/uniops/application.ex` — add `Uniops.Services.Registry` to `cluster_children`:

```elixir
  defp cluster_children do
    [
      Uniops.Cluster.HashCache,
      Uniops.Cluster.SyncServer,
      Uniops.Services.Registry
    ]
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/uniops/services_test.exs`
Expected: 5 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
jj desc -m "Add Services module: deploy, call, list, undeploy"
jj new
```

---

### Task 3: HTTP API for Services

**Files:**
- Create: `lib/uniops/api/services_controller.ex`
- Modify: `lib/uniops/api/router.ex`
- Create: `test/uniops/api/services_api_test.exs`

Add HTTP endpoints so Unison programs can deploy and call services via the HTTP API.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/api/services_api_test.exs`:

```elixir
defmodule Uniops.API.ServicesAPITest do
  use ExUnit.Case, async: false
  use Plug.Test

  @moduletag timeout: 300_000

  defp call(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> Uniops.API.Router.call(Uniops.API.Router.init([]))
  end

  describe "POST /services/deploy" do
    test "deploys a service and returns its info" do
      body = Jason.encode!(%{
        name: "api_svc",
        source: "main : '{IO, Exception} ()\nmain = do printLine \"api-deployed\""
      })

      conn = conn(:post, "/services/deploy", body) |> call()
      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)
      assert resp["name"] == "api_svc"
      assert is_binary(resp["hash"])
    end
  end

  describe "POST /services/:name/call" do
    test "calls a deployed service" do
      # Deploy first
      deploy_body = Jason.encode!(%{
        name: "callable",
        source: "main : '{IO, Exception} ()\nmain = do printLine \"called-via-api\""
      })
      conn(:post, "/services/deploy", deploy_body) |> call()

      # Call it
      conn = conn(:post, "/services/callable/call") |> call()
      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["stdout"] =~ "called-via-api"
    end

    test "returns 404 for unknown service" do
      conn = conn(:post, "/services/unknown_svc/call") |> call()
      assert conn.status == 404
    end
  end

  describe "GET /services" do
    test "lists deployed services" do
      conn = conn(:get, "/services") |> call()
      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert is_list(resp["services"])
    end
  end

  describe "DELETE /services/:name" do
    test "undeploys a service" do
      deploy_body = Jason.encode!(%{
        name: "deleteme",
        source: "main : '{IO, Exception} ()\nmain = do printLine \"delete\""
      })
      conn(:post, "/services/deploy", deploy_body) |> call()

      conn = conn(:delete, "/services/deleteme") |> call()
      assert conn.status == 200

      conn = conn(:post, "/services/deleteme/call") |> call()
      assert conn.status == 404
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/api/services_api_test.exs`
Expected: FAIL — routes not found (404)

- [ ] **Step 3: Implement the services controller**

Create `lib/uniops/api/services_controller.ex`:

```elixir
defmodule Uniops.API.ServicesController do
  @moduledoc false

  alias Uniops.API.Json
  alias Uniops.Services

  def deploy(conn) do
    {:ok, %{"name" => name, "source" => source}} = Json.read_json(conn)

    case Services.deploy(name, source) do
      {:ok, info} ->
        Json.send_json(conn, 201, %{
          name: info.name,
          hash: info.hash,
          node: Atom.to_string(info.node)
        })

      {:error, reason} ->
        Json.send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  def call(conn, name) do
    case Services.call(name) do
      {:ok, result} ->
        Json.send_json(conn, 200, %{
          stdout: result.stdout,
          stderr: result.stderr,
          exit_code: result.exit_code
        })

      {:error, :not_found} ->
        Json.send_json(conn, 404, %{error: "service not found", name: name})

      {:error, reason} ->
        Json.send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  def list(conn) do
    services =
      Services.list()
      |> Enum.map(fn entry ->
        %{name: entry.name, hash: entry.hash, node: Atom.to_string(entry.node)}
      end)

    Json.send_json(conn, 200, %{services: services})
  end

  def undeploy(conn, name) do
    :ok = Services.undeploy(name)
    Json.send_json(conn, 200, %{name: name, status: "undeployed"})
  end
end
```

- [ ] **Step 4: Add routes to the router**

Add these routes to `lib/uniops/api/router.ex`, before the `match _` catch-all:

```elixir
  # Service endpoints
  post "/services/deploy" do
    Uniops.API.ServicesController.deploy(conn)
  end

  post "/services/:name/call" do
    Uniops.API.ServicesController.call(conn, name)
  end

  get "/services" do
    Uniops.API.ServicesController.list(conn)
  end

  delete "/services/:name" do
    Uniops.API.ServicesController.undeploy(conn, name)
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/uniops/api/services_api_test.exs`
Expected: 5 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
jj desc -m "Add HTTP API endpoints for services (deploy, call, list, undeploy)"
jj new
```

---

### Task 4: Multi-Node Services Test

**Files:**
- Create: `test/integration/services_cluster_test.exs`

Deploy a service on node A, call it from node B by name.

- [ ] **Step 1: Write the multi-node test**

Create `test/integration/services_cluster_test.exs`:

```elixir
defmodule Uniops.Integration.ServicesClusterTest do
  use ExUnit.Case, async: false

  alias Uniops.Cluster.{HashCache, SyncServer}
  alias Uniops.Services.Registry

  @moduletag timeout: 300_000

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:uniops_svc_test, :shortnames])
    end

    :ok
  end

  setup do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    {:ok, pid, peer} = :peer.start_link(%{name: :svc_peer, args: pa_args})

    {:ok, _} = :rpc.call(peer, Application, :ensure_all_started, [:crypto])
    {:ok, _} = :rpc.call(peer, GenServer, :start, [HashCache, HashCache, [name: HashCache]])
    {:ok, _} = :rpc.call(peer, GenServer, :start, [SyncServer, %{cache: HashCache}, [name: SyncServer]])
    {:ok, _} = :rpc.call(peer, GenServer, :start, [Registry, [name: Registry], [name: Registry]])

    on_exit(fn ->
      try do
        :peer.stop(pid)
      catch
        _, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  test "deploy on local, call from peer by name", %{peer: peer} do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"cross-node-svc\""
    {:ok, _info} = Uniops.Services.deploy("remote_greeter", source)

    # Peer calls the service by name — resolves from us
    result = :rpc.call(peer, Uniops.Services, :call, ["remote_greeter"], 120_000)
    assert {:ok, run_result} = result
    assert run_result.stdout =~ "cross-node-svc"
  end

  test "list on peer shows services from local", %{peer: peer} do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"listed\""
    {:ok, _} = Uniops.Services.deploy("visible_svc", source)

    # Peer can't see it in its own local registry
    peer_local = :rpc.call(peer, Registry, :lookup, [Registry, "visible_svc"])
    assert peer_local == :not_found

    # But resolve (which asks peers) finds it
    {:ok, entry} = :rpc.call(peer, Registry, :resolve, [Registry, "visible_svc"], 10_000)
    assert entry.name == "visible_svc"
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/integration/services_cluster_test.exs`
Expected: 2 tests, 0 failures

**Debugging notes:**
- The Registry on the peer is started with `GenServer.start` (not `start_link`). The init arg is the opts keyword list, same as `start_link` would receive.
- `Services.call/1` on the peer uses `Registry.resolve/1` which asks peers if local lookup fails. It then uses `Remote.execute/2` with the bytecode hash, which triggers `SyncServer.resolve/1` to pull the bytecode from us.
- If the peer's `Services.call` fails with `:not_found`, the issue is likely in `Registry.resolve` not reaching our node. Check `Node.list()` on the peer.

- [ ] **Step 3: Commit**

```bash
jj desc -m "Add multi-node services integration test"
jj new
```

---

### Task 5: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: All tests pass (~82 total)

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation

- [ ] **Step 3: Commit final state**

```bash
jj desc -m "Complete Plan 5: Services registry with deploy, call, and cross-node discovery"
```

---

## What This Plan Produces

1. **Services.Registry** — GenServer + ETS mapping service names to bytecode hashes, with cross-node peer lookup
2. **Services.deploy/2** — compile Unison source → cache bytecode → register name
3. **Services.call/2** — look up by name (local + peers) → Remote.execute
4. **HTTP API** — `/services/deploy`, `/services/:name/call`, `GET /services`, `DELETE /services/:name`
5. **Multi-node proof** — deploy on node A, call by name from node B

Combined with Plans 1-4, the system now supports: compile Unison, store durably, cluster nodes, ship computations, and register/call named services. Plan 6 adds the remaining abilities: Config, Blobs, Scratch, Log.
