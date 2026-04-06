# Cluster Ergonomics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace manual multi-terminal iex-flag cluster setup with zero-config single-node startup, env-var-driven clustering, auto-peer-connect, and a production Mix release.

**Architecture:** A `ConfigResolver` module centralizes the env var > config file > defaults lookup. `PeerConnector` GenServer handles auto-connect with backoff. `mix unex.start` re-execs with VM distribution flags when needed. The Mix release uses `rel/env.sh.eex` for the same. Tests never start distribution or the API.

**Tech Stack:** Elixir 1.19 / OTP 28, Mix releases, GenServer, BEAM distribution

---

## File Structure

```
lib/unex/
  config_resolver.ex              # Env var > config file > defaults resolution
  cluster/peer_connector.ex       # Auto-connect to peers with backoff
  application.ex                  # Modify: use ConfigResolver, add PeerConnector, always start API
  abilities/config.ex             # Modify: remove hardcoded default key, use ConfigResolver
config/
  config.exs                      # Simplify: minimal compile-time config
  runtime.exs                     # Create: unified runtime config resolution
  test.exs                        # Modify: keep tests isolated
rel/
  env.sh.eex                      # VM flag injection for releases
mix.exs                           # Modify: add release config
lib/mix/tasks/unex.start.ex    # mix unex.start task
config.example.exs                # Reference config file
test/unex/
  config_resolver_test.exs        # Tests for config resolution
  cluster/peer_connector_test.exs # Tests for peer connector
```

---

### Task 1: ConfigResolver

**Files:**
- Create: `test/unex/config_resolver_test.exs`
- Create: `lib/unex/config_resolver.ex`

ConfigResolver is a pure module (no GenServer) that reads env vars, optionally loads a config file, merges with defaults, and validates. Everything else in the system calls `ConfigResolver.resolve/0` to get the final config.

- [ ] **Step 1: Write the failing tests**

Create `test/unex/config_resolver_test.exs`:

```elixir
defmodule Unex.ConfigResolverTest do
  use ExUnit.Case, async: true

  alias Unex.ConfigResolver

  describe "defaults/0" do
    test "returns sensible single-node defaults" do
      defaults = ConfigResolver.defaults()
      assert defaults.api_port == 4040
      assert defaults.data_dir == "./data"
      assert defaults.node_name == nil
      assert defaults.cookie == nil
      assert defaults.peers == []
      assert defaults.config_encryption_key == nil
      assert defaults.ucm_path == "ucm"
    end
  end

  describe "resolve_env/0" do
    test "reads UNEX_PORT" do
      System.put_env("UNEX_PORT", "5050")
      on_exit(fn -> System.delete_env("UNEX_PORT") end)

      env = ConfigResolver.resolve_env()
      assert env.api_port == 5050
    end

    test "reads UNEX_NODE" do
      System.put_env("UNEX_NODE", "mynode")
      on_exit(fn -> System.delete_env("UNEX_NODE") end)

      env = ConfigResolver.resolve_env()
      assert env.node_name == "mynode"
    end

    test "reads UNEX_PEERS as comma-separated list" do
      System.put_env("UNEX_PEERS", "b@host1,c@host2")
      on_exit(fn -> System.delete_env("UNEX_PEERS") end)

      env = ConfigResolver.resolve_env()
      assert env.peers == ["b@host1", "c@host2"]
    end

    test "ignores unset env vars" do
      env = ConfigResolver.resolve_env()
      assert env.node_name == nil
      assert env.peers == nil
    end
  end

  describe "merge/2" do
    test "env overrides defaults" do
      defaults = %{api_port: 4040, node_name: nil}
      env = %{api_port: 5050, node_name: nil}
      merged = ConfigResolver.merge(defaults, env)
      assert merged.api_port == 5050
    end

    test "nil env values do not override" do
      defaults = %{api_port: 4040, node_name: nil}
      env = %{api_port: nil, node_name: "a"}
      merged = ConfigResolver.merge(defaults, env)
      assert merged.api_port == 4040
      assert merged.node_name == "a"
    end
  end

  describe "validate!/1" do
    test "passes with valid single-node config" do
      config = ConfigResolver.defaults()
      assert ConfigResolver.validate!(config) == config
    end

    test "raises when UNEX_NODE set without UNEX_COOKIE" do
      config = %{ConfigResolver.defaults() | node_name: "a", cookie: nil}

      assert_raise ArgumentError, ~r/UNEX_COOKIE is required/, fn ->
        ConfigResolver.validate!(config)
      end
    end

    test "raises when UNEX_PEERS set without UNEX_NODE" do
      config = %{ConfigResolver.defaults() | peers: ["b@host"], node_name: nil}

      assert_raise ArgumentError, ~r/UNEX_NODE is required/, fn ->
        ConfigResolver.validate!(config)
      end
    end

    test "passes with node + cookie + peers" do
      config = %{ConfigResolver.defaults() | node_name: "a", cookie: "secret", peers: ["b@host"]}
      assert ConfigResolver.validate!(config) == config
    end
  end

  describe "derive_paths/1" do
    test "derives mnesia_dir and blobs_dir from data_dir" do
      config = %{ConfigResolver.defaults() | data_dir: "/var/data/unex"}
      derived = ConfigResolver.derive_paths(config)
      assert derived.mnesia_dir == "/var/data/unex/mnesia"
      assert derived.blobs_dir == "/var/data/unex/blobs"
    end
  end

  describe "resolve_encryption_key/1" do
    test "returns config as-is when key is set" do
      config = %{ConfigResolver.defaults() | config_encryption_key: "my-secret"}
      {resolved, generated?} = ConfigResolver.resolve_encryption_key(config)
      assert resolved.config_encryption_key == "my-secret"
      refute generated?
    end

    test "generates a random key when none is set" do
      config = ConfigResolver.defaults()
      {resolved, generated?} = ConfigResolver.resolve_encryption_key(config)
      assert is_binary(resolved.config_encryption_key)
      assert byte_size(resolved.config_encryption_key) > 0
      assert generated?
    end
  end

  describe "node_type/1" do
    test "returns :sname for short name" do
      assert ConfigResolver.node_type("a") == :sname
    end

    test "returns :name for FQDN" do
      assert ConfigResolver.node_type("a@10.0.1.5") == :name
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/unex/config_resolver_test.exs`
Expected: compilation error — `Unex.ConfigResolver` not found

- [ ] **Step 3: Implement ConfigResolver**

Create `lib/unex/config_resolver.ex`:

```elixir
defmodule Unex.ConfigResolver do
  @moduledoc """
  Resolves Unex configuration from env vars > config file > defaults.
  """

  defstruct [
    :node_name,
    :cookie,
    :config_encryption_key,
    api_port: 4040,
    data_dir: "./data",
    mnesia_dir: nil,
    blobs_dir: nil,
    peers: [],
    ucm_path: "ucm"
  ]

  @type t :: %__MODULE__{}

  @doc "Returns default config values for single-node operation."
  def defaults do
    %__MODULE__{}
  end

  @doc "Reads config from environment variables. Unset vars are nil."
  def resolve_env do
    %{
      node_name: System.get_env("UNEX_NODE"),
      cookie: System.get_env("UNEX_COOKIE"),
      api_port: parse_int(System.get_env("UNEX_PORT")),
      data_dir: System.get_env("UNEX_DATA"),
      peers: parse_peers(System.get_env("UNEX_PEERS")),
      config_encryption_key: System.get_env("UNEX_CONFIG_KEY"),
      ucm_path: System.get_env("UCM_PATH")
    }
  end

  @doc "Merges two configs. Non-nil values in `override` win."
  def merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      if override_val == nil, do: base_val, else: override_val
    end)
  end

  @doc "Validates config. Raises ArgumentError on invalid combinations."
  def validate!(config) do
    if config.node_name && !config.cookie do
      raise ArgumentError, "UNEX_COOKIE is required when UNEX_NODE is set"
    end

    if config.peers != [] && config.peers != nil && !config.node_name do
      raise ArgumentError, "UNEX_NODE is required when UNEX_PEERS is set"
    end

    config
  end

  @doc "Derives mnesia_dir and blobs_dir from data_dir."
  def derive_paths(config) do
    %{config |
      mnesia_dir: Path.join(config.data_dir, "mnesia"),
      blobs_dir: Path.join(config.data_dir, "blobs")
    }
  end

  @doc """
  Ensures an encryption key exists. If none is configured, generates a random one.
  Returns `{updated_config, generated?}`.
  """
  def resolve_encryption_key(config) do
    if config.config_encryption_key do
      {config, false}
    else
      key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      {%{config | config_encryption_key: key}, true}
    end
  end

  @doc "Returns :sname for short names, :name for FQDN (contains @)."
  def node_type(name) when is_binary(name) do
    if String.contains?(name, "@"), do: :name, else: :sname
  end

  @doc """
  Full resolution pipeline: defaults -> config file -> env vars -> validate -> derive.
  Returns `{config, key_generated?}`.
  """
  def resolve do
    file_config = load_config_file()

    config =
      defaults()
      |> to_map()
      |> merge(file_config)
      |> merge(resolve_env())
      |> to_struct()
      |> validate!()
      |> derive_paths()

    resolve_encryption_key(config)
  end

  defp load_config_file do
    path = config_file_path()

    if path && File.exists?(path) do
      [{:unex, opts}] =
        path
        |> Config.Reader.read!()
        |> Keyword.get(:unex, [])
        |> then(fn opts -> [{:unex, opts}] end)

      Map.new(opts)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp config_file_path do
    System.get_env("UNEX_CONFIG") ||
      find_default_config_file()
  end

  defp find_default_config_file do
    candidates = [
      Path.expand("~/.config/unex/config.exs"),
      "/etc/unex/config.exs"
    ]

    Enum.find(candidates, &File.exists?/1)
  end

  defp parse_int(nil), do: nil
  defp parse_int(str), do: String.to_integer(str)

  defp parse_peers(nil), do: nil
  defp parse_peers(""), do: []
  defp parse_peers(str), do: String.split(str, ",", trim: true) |> Enum.map(&String.trim/1)

  defp to_map(%__MODULE__{} = s), do: Map.from_struct(s)
  defp to_map(m) when is_map(m), do: m

  defp to_struct(map) when is_map(map) do
    struct(__MODULE__, map)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/unex/config_resolver_test.exs`
Expected: 11 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add ConfigResolver: env var > config file > defaults resolution"
jj new
```

---

### Task 2: PeerConnector GenServer

**Files:**
- Create: `test/unex/cluster/peer_connector_test.exs`
- Create: `lib/unex/cluster/peer_connector.ex`

PeerConnector tries to connect to a list of peer nodes with exponential backoff. It's supervised, but only started when distribution is enabled.

- [ ] **Step 1: Write the failing tests**

Create `test/unex/cluster/peer_connector_test.exs`:

```elixir
defmodule Unex.Cluster.PeerConnectorTest do
  use ExUnit.Case, async: false

  alias Unex.Cluster.PeerConnector

  describe "parse_peers/1" do
    test "converts string peer names to atoms" do
      assert PeerConnector.parse_peers(["a@host1", "b@host2"]) == [:"a@host1", :"b@host2"]
    end

    test "handles empty list" do
      assert PeerConnector.parse_peers([]) == []
    end
  end

  describe "start_link/1" do
    test "starts with empty peer list" do
      pid = start_supervised!({PeerConnector, peers: [], name: :test_peer_connector})
      assert Process.alive?(pid)
    end

    test "starts with unreachable peers without crashing" do
      pid =
        start_supervised!(
          {PeerConnector,
           peers: ["nonexistent@nowhere"],
           name: :test_peer_connector_unreachable,
           connect_interval: 100}
        )

      # Give it time to attempt connection
      Process.sleep(200)
      assert Process.alive?(pid)
    end
  end

  describe "status/1" do
    test "reports peer connection status" do
      pid = start_supervised!({PeerConnector, peers: [], name: :test_status_connector})
      status = PeerConnector.status(pid)
      assert is_map(status)
      assert status.peers == []
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/unex/cluster/peer_connector_test.exs`
Expected: compilation error — `Unex.Cluster.PeerConnector` not found

- [ ] **Step 3: Implement PeerConnector**

Create `lib/unex/cluster/peer_connector.ex`:

```elixir
defmodule Unex.Cluster.PeerConnector do
  @moduledoc """
  Automatically connects to declared peer nodes with exponential backoff.
  Only started when BEAM distribution is enabled (UNEX_NODE is set).
  """

  use GenServer

  require Logger

  @default_interval 1_000
  @max_interval 30_000
  @recheck_interval 30_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current connection status."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Converts a list of string peer names to atoms."
  def parse_peers(peers) when is_list(peers) do
    Enum.map(peers, fn
      peer when is_atom(peer) -> peer
      peer when is_binary(peer) -> String.to_atom(peer)
    end)
  end

  @impl true
  def init(opts) do
    peers = Keyword.get(opts, :peers, []) |> parse_peers()
    interval = Keyword.get(opts, :connect_interval, @default_interval)

    state = %{
      peers: peers,
      connected: MapSet.new(),
      backoffs: Map.new(peers, fn p -> {p, interval} end),
      base_interval: interval
    }

    if peers != [] do
      send(self(), :connect)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state = attempt_connections(state)
    schedule_recheck(state)
    {:noreply, state}
  end

  def handle_info({:retry, peer}, state) do
    state = try_connect(state, peer)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      peers: state.peers,
      connected: MapSet.to_list(state.connected),
      pending: state.peers -- MapSet.to_list(state.connected)
    }

    {:reply, status, state}
  end

  defp attempt_connections(state) do
    Enum.reduce(state.peers, state, fn peer, acc ->
      try_connect(acc, peer)
    end)
  end

  defp try_connect(state, peer) do
    if MapSet.member?(state.connected, peer) do
      state
    else
      case Node.connect(peer) do
        true ->
          Logger.info("[unex] Connected to peer #{peer}")
          %{state | connected: MapSet.put(state.connected, peer)}

        _ ->
          backoff = Map.get(state.backoffs, peer, state.base_interval)
          Logger.warning("[unex] Failed to connect to #{peer}, retrying in #{backoff}ms")
          Process.send_after(self(), {:retry, peer}, backoff)
          new_backoff = min(backoff * 2, @max_interval)
          %{state | backoffs: Map.put(state.backoffs, peer, new_backoff)}
      end
    end
  end

  defp schedule_recheck(state) do
    if state.peers != [] do
      Process.send_after(self(), :connect, @recheck_interval)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/unex/cluster/peer_connector_test.exs`
Expected: 5 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add PeerConnector: auto-connect to cluster peers with backoff"
jj new
```

---

### Task 3: Rewrite config/runtime.exs and Application Startup

**Files:**
- Create: `config/runtime.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `lib/unex/application.ex`
- Modify: `lib/unex/abilities/config.ex:74-76`

This task wires ConfigResolver into the actual application startup. The API always starts (except in tests). PeerConnector starts only when distribution is enabled.

- [ ] **Step 1: Write `config/runtime.exs`**

**Important:** `runtime.exs` in a Mix release is evaluated before application code loads, so it cannot call `Unex.ConfigResolver`. All resolution logic must be inline here. `ConfigResolver` is still useful for the Mix task and programmatic access, but `runtime.exs` does its own resolution.

Create `config/runtime.exs`:

```elixir
import Config

if config_env() != :test do
  # --- Config file loading ---
  config_path =
    System.get_env("UNEX_CONFIG") ||
      Enum.find(
        [Path.expand("~/.config/unex/config.exs"), "/etc/unex/config.exs"],
        &File.exists?/1
      )

  file_config =
    if config_path && File.exists?(config_path) do
      [{:unex, opts}] = Config.Reader.read!(config_path) |> Keyword.take([:unex])
      Map.new(opts)
    else
      %{}
    end

  # --- Helpers ---
  get = fn env_var, file_key, default ->
    case System.get_env(env_var) do
      nil -> Map.get(file_config, file_key, default)
      val -> val
    end
  end

  get_int = fn env_var, file_key, default ->
    case System.get_env(env_var) do
      nil -> Map.get(file_config, file_key, default)
      val -> String.to_integer(val)
    end
  end

  # --- Resolve values ---
  data_dir = get.("UNEX_DATA", :data_dir, "./data")
  node_name = get.("UNEX_NODE", :node_name, nil)
  cookie = get.("UNEX_COOKIE", :cookie, nil)

  peers_raw = System.get_env("UNEX_PEERS")
  peers =
    cond do
      peers_raw != nil -> String.split(peers_raw, ",", trim: true) |> Enum.map(&String.trim/1)
      Map.has_key?(file_config, :peers) -> file_config.peers
      true -> []
    end

  encryption_key = get.("UNEX_CONFIG_KEY", :config_encryption_key, nil)

  {encryption_key, key_generated?} =
    if encryption_key do
      {encryption_key, false}
    else
      key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      {key, true}
    end

  # --- Validation ---
  if node_name && !cookie do
    raise "UNEX_COOKIE is required when UNEX_NODE is set"
  end

  if peers != [] && !node_name do
    raise "UNEX_NODE is required when UNEX_PEERS is set"
  end

  # --- Apply config ---
  config :unex,
    api_port: get_int.("UNEX_PORT", :api_port, 4040),
    mnesia_dir: Path.join(data_dir, "mnesia"),
    blobs_dir: Path.join(data_dir, "blobs"),
    config_encryption_key: encryption_key,
    ucm_path: get.("UCM_PATH", :ucm_path, "ucm"),
    peers: peers,
    node_name: node_name,
    cookie: cookie,
    start_api: true

  if key_generated? do
    IO.puts("[unex] No encryption key configured. Generated: #{encryption_key}")
    IO.puts("[unex] Set UNEX_CONFIG_KEY to persist this key across restarts.")
    IO.puts("[unex] WARNING: If the key changes, existing encrypted Config values become unreadable.")
  end
end
```

- [ ] **Step 2: Simplify `config/config.exs`**

Replace the contents of `config/config.exs` with:

```elixir
import Config

# Compile-time defaults. Runtime config in config/runtime.exs overrides these.
config :unex,
  ucm_path: "ucm",
  ucm_timeout: 30_000,
  workspace_base: Path.join(System.tmp_dir!(), "unex"),
  api_port: 4040,
  start_api: false

import_config "#{config_env()}.exs"
```

- [ ] **Step 3: Update `config/test.exs`**

Replace the contents of `config/test.exs` with:

```elixir
import Config

# Tests manage their own Mnesia and API instances — don't auto-start anything
config :unex,
  start_api: false,
  mnesia_dir: nil,
  blobs_dir: nil,
  config_encryption_key: "test-key-not-for-production"
```

- [ ] **Step 4: Update `application.ex` to use ConfigResolver**

Replace the contents of `lib/unex/application.ex` with:

```elixir
defmodule Unex.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    mnesia_dir = Application.get_env(:unex, :mnesia_dir)
    if mnesia_dir, do: Unex.Storage.Schema.init(mnesia_dir)

    children = cluster_children() ++ peer_children() ++ api_children()
    Supervisor.start_link(children, strategy: :one_for_one, name: Unex.Supervisor)
  end

  defp cluster_children do
    [
      Unex.Cluster.HashCache,
      Unex.Cluster.SyncServer,
      Unex.Services.Registry,
      Unex.Abilities.Scratch,
      Unex.Abilities.Log
    ]
  end

  defp peer_children do
    peers = Application.get_env(:unex, :peers, [])

    if peers != [] do
      [{Unex.Cluster.PeerConnector, peers: peers}]
    else
      []
    end
  end

  defp api_children do
    if Application.get_env(:unex, :start_api, false) do
      port = Application.get_env(:unex, :api_port, 4040)
      [{Bandit, plug: Unex.API.Router, port: port}]
    else
      []
    end
  end
end
```

- [ ] **Step 5: Remove hardcoded default encryption key from Config**

In `lib/unex/abilities/config.ex`, change line 75 from:

```elixir
  defp encryption_key do
    configured = Application.get_env(:unex, :config_encryption_key, "unex-default-key-change-me!")
    :crypto.hash(:sha256, configured)
  end
```

to:

```elixir
  defp encryption_key do
    configured = Application.get_env(:unex, :config_encryption_key)

    unless configured do
      raise "No encryption key configured. Set UNEX_CONFIG_KEY environment variable."
    end

    :crypto.hash(:sha256, configured)
  end
```

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: All existing tests pass. The test env has `config_encryption_key: "test-key-not-for-production"` so Config tests still work.

- [ ] **Step 7: Commit**

```bash
jj desc -m "Wire ConfigResolver into runtime config and application startup"
jj new
```

---

### Task 4: Mix Task — `mix unex.start`

**Files:**
- Create: `lib/mix/tasks/unex.start.ex`

The Mix task reads config, validates it, and either starts the app directly (no distribution) or re-execs with `--sname`/`--name` and `--cookie` flags to enable BEAM distribution.

- [ ] **Step 1: Create the Mix task**

Create `lib/mix/tasks/unex.start.ex`:

```elixir
defmodule Mix.Tasks.Unex.Start do
  @moduledoc """
  Starts a Unex node.

  ## Usage

      mix unex.start                          # single node, zero config
      mix unex.start --config path/to/config.exs  # with config file

  ## Environment Variables

  All UNEX_* env vars are supported. See ConfigResolver for details.

  When UNEX_NODE is set, the task re-launches with BEAM distribution flags
  and drops into an IEx shell.
  """

  use Mix.Task

  @shortdoc "Start a Unex node"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [config: :string])

    if config_path = opts[:config] do
      System.put_env("UNEX_CONFIG", config_path)
    end

    node_name = System.get_env("UNEX_NODE")
    cookie = System.get_env("UNEX_COOKIE")

    if node_name do
      reexec_with_distribution(node_name, cookie)
    else
      start_without_distribution()
    end
  end

  defp reexec_with_distribution(node_name, cookie) do
    unless cookie do
      Mix.raise("UNEX_COOKIE is required when UNEX_NODE is set")
    end

    node_flag =
      if String.contains?(node_name, "@"),
        do: "--name",
        else: "--sname"

    # Build the iex command with distribution flags
    args = [
      node_flag, node_name,
      "--cookie", cookie,
      "--erl", "-noinput",
      "-S", "mix", "run", "--no-halt"
    ]

    # Re-exec as iex with distribution enabled
    iex_path = System.find_executable("iex") || "iex"

    Port.open({:spawn_executable, iex_path}, [
      :binary,
      :nouse_stdio,
      args: args
    ])

    # Keep the current process alive so the port stays open
    receive do
      _ -> :ok
    end
  end

  defp start_without_distribution do
    # Start the application with API enabled
    Application.put_env(:unex, :start_api, true)
    Mix.Task.run("app.start")

    port = Application.get_env(:unex, :api_port, 4040)
    IO.puts("[unex] API listening on http://localhost:#{port}")
    IO.puts("[unex] Press Ctrl+C to stop")

    # Block forever
    Process.sleep(:infinity)
  end
end
```

- [ ] **Step 2: Verify the task is discoverable**

Run: `mix help unex.start`
Expected: Shows the task moduledoc

- [ ] **Step 3: Smoke test — single node**

Run: `mix unex.start`
Expected: Starts up, prints API port, serves `/health`

Verify in another terminal:
```bash
curl -s localhost:4040/health
# {"status":"ok"}
```

Then Ctrl+C to stop.

- [ ] **Step 4: Commit**

```bash
jj desc -m "Add mix unex.start task for easy node startup"
jj new
```

---

### Task 5: Mix Release Configuration

**Files:**
- Create: `rel/env.sh.eex`
- Modify: `mix.exs`
- Create: `config.example.exs`

- [ ] **Step 1: Create `rel/env.sh.eex`**

Create `rel/env.sh.eex`:

```bash
#!/bin/sh

# Translate UNEX_NODE and UNEX_COOKIE into BEAM VM flags.
# This runs before the BEAM starts, so it can set --sname/--name and --cookie.

if [ -n "$UNEX_NODE" ]; then
  case "$UNEX_NODE" in
    *@*)
      export RELEASE_DISTRIBUTION=name
      export RELEASE_NODE="$UNEX_NODE"
      ;;
    *)
      export RELEASE_DISTRIBUTION=sname
      export RELEASE_NODE="$UNEX_NODE"
      ;;
  esac
fi

if [ -n "$UNEX_COOKIE" ]; then
  export RELEASE_COOKIE="$UNEX_COOKIE"
fi
```

- [ ] **Step 2: Add release config to `mix.exs`**

In `mix.exs`, add the `releases` key to the `project/0` function:

```elixir
  def project do
    [
      app: :unex,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  defp releases do
    [
      unex: [
        include_executables_for: [:unix],
        rel_templates_path: "rel"
      ]
    ]
  end
```

- [ ] **Step 3: Create `config.example.exs`**

Create `config.example.exs` at the project root:

```elixir
# Unex configuration file example.
#
# Copy this file and point to it:
#   UNEX_CONFIG=/path/to/config.exs mix unex.start
#
# Or place it at one of the default locations:
#   ~/.config/unex/config.exs
#   /etc/unex/config.exs
#
# Environment variables always override values from this file.

import Config

config :unex,
  # Node identity (required for clustering)
  # node_name: "a",                              # short name (same subnet) — or "a@10.0.1.5" for cross-network
  # cookie: "unex_secret",                     # must match on all cluster nodes

  # HTTP API
  api_port: 4040,

  # Data storage
  data_dir: "./data",                             # Mnesia and blobs stored under this directory

  # Cluster peers (auto-connect on startup)
  # peers: ["b@10.0.1.2", "c@10.0.1.3"],

  # Config encryption key (AES-256-GCM, base64-encoded)
  # If not set, a random key is generated at startup (printed to stdout).
  # WARNING: changing this key makes existing encrypted Config values unreadable.
  # config_encryption_key: "base64-encoded-32-byte-key",

  # UCM binary path
  ucm_path: "ucm"
```

- [ ] **Step 4: Verify release builds**

Run: `MIX_ENV=prod mix release`
Expected: Produces `_build/prod/rel/unex/bin/unex`

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add Mix release config and config.example.exs"
jj new
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

Replace the "Quick start", "Running a cluster", and "Configuration" sections to reflect the new ergonomics.

- [ ] **Step 1: Update README Quick Start section**

Replace the Quick start section (from `## Quick start` to the `curl` health check) with:

````markdown
## Quick start

```bash
# Prerequisites: Elixir 1.17+, UCM (Unison Codebase Manager)
mix deps.get
mix unex.start
```

The API starts on `http://localhost:4040` with zero configuration.

Verify it works:

```bash
curl -s localhost:4040/health
# {"status":"ok"}
```
````

- [ ] **Step 2: Replace the "Running a cluster" section**

Replace everything from `## Running a cluster` through the end of the remote execution section with:

````markdown
## Running a cluster

Unex nodes use BEAM's built-in distribution to form clusters. Set a few environment variables and nodes auto-connect.

### Starting a two-node cluster

**Terminal 1 — node `a`:**

```bash
UNEX_NODE=a UNEX_COOKIE=secret UNEX_PORT=4040 UNEX_PEERS=b@$(hostname) mix unex.start
```

**Terminal 2 — node `b`:**

```bash
UNEX_NODE=b UNEX_COOKIE=secret UNEX_PORT=4041 UNEX_PEERS=a@$(hostname) mix unex.start
```

Nodes auto-connect — no manual `Node.connect` needed. Check from IEx:

```elixir
Node.list()
# => [:"a@myhostname"]
```

### Using a config file

For complex setups, use a config file instead of env vars:

```bash
# Copy the example
cp config.example.exs mynode.exs
# Edit it, then start
UNEX_CONFIG=mynode.exs mix unex.start
```

Config files can also live at `~/.config/unex/config.exs` or `/etc/unex/config.exs`.

### Production deployment

Build a standalone release:

```bash
MIX_ENV=prod mix release
```

Run it:

```bash
# Single node
./bin/unex start

# Cluster node
UNEX_NODE=a UNEX_COOKIE=secret UNEX_PEERS=b@10.0.1.2 ./bin/unex start

# Attach console to running node
./bin/unex remote
```
````

- [ ] **Step 3: Replace the "Configuration" section**

Replace the Configuration section with:

````markdown
## Configuration

Unex resolves config in this order (first wins): environment variables → config file → built-in defaults.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UNEX_NODE` | *(none)* | Node name. Short name (`a`) for same subnet, FQDN (`a@10.0.1.5`) for cross-network |
| `UNEX_COOKIE` | *(none)* | Cluster auth cookie (required if `UNEX_NODE` is set) |
| `UNEX_PORT` | `4040` | HTTP API port |
| `UNEX_DATA` | `./data` | Base directory for Mnesia and blob storage |
| `UNEX_PEERS` | *(none)* | Comma-separated peer nodes to auto-connect |
| `UNEX_CONFIG_KEY` | *(generated)* | AES-256-GCM encryption key for Config secrets |
| `UNEX_CONFIG` | *(none)* | Path to config file |
| `UCM_PATH` | `ucm` | Path to UCM binary |

### Config file

See `config.example.exs` for a complete reference. Place at `~/.config/unex/config.exs`, `/etc/unex/config.exs`, or point to it with `UNEX_CONFIG`.
````

- [ ] **Step 4: Run tests to verify nothing broke**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
jj desc -m "Update README with new cluster ergonomics and config docs"
jj new
```

---

### Task 7: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation

- [ ] **Step 3: Verify single-node startup**

Run: `mix unex.start`
Expected:
- Prints generated encryption key warning
- API serves `/health` on port 4040

- [ ] **Step 4: Verify release builds**

Run: `MIX_ENV=prod mix release`
Expected: Clean build

- [ ] **Step 5: Final commit**

```bash
jj desc -m "Complete Plan 7: cluster ergonomics with config resolution, auto-connect, release"
```
