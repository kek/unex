# Supporting Abilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the Uniops ability set with Config (encrypted secrets), Blobs (binary object storage), Scratch (ephemeral in-memory cache), and Log (structured logging) — all exposed via the HTTP API.

**Architecture:** Each ability is a focused module with its own storage backend: Config uses Mnesia with AES-256-GCM encryption, Blobs uses the filesystem, Scratch uses a node-local ETS table, and Log uses an ETS ring buffer. Each gets an HTTP controller added to the existing router. All four are independent and can be implemented in parallel.

**Tech Stack:** Elixir 1.19 / OTP 28, Mnesia (Config), filesystem (Blobs), ETS (Scratch, Log), `:crypto` (AES-256-GCM encryption)

---

## Scope Note

This is Plan 6 of 6 — the final plan. These four abilities are the remaining pieces from the Unison Cloud ability set. After this, Uniops provides open-source equivalents for: Storage, Remote, Services, Config, Blobs, Scratch, and Log.

## File Structure

```
lib/
  uniops/
    abilities/
      config.ex                     # Encrypted key-value secrets (Mnesia + AES-256-GCM)
      blobs.ex                      # Binary object storage (filesystem)
      scratch.ex                    # Ephemeral in-memory cache (ETS, node-local)
      log.ex                        # Structured log with ring buffer (ETS)
    api/
      router.ex                     # Modify: add routes for all four abilities
      config_controller.ex          # HTTP handlers for /config
      blobs_controller.ex           # HTTP handlers for /blobs
      scratch_controller.ex         # HTTP handlers for /scratch
      log_controller.ex             # HTTP handlers for /log
    application.ex                  # Modify: add Scratch + Log to supervision tree
test/
  uniops/
    abilities/
      config_test.exs
      blobs_test.exs
      scratch_test.exs
      log_test.exs
    api/
      abilities_api_test.exs        # HTTP tests for all four
```

---

### Task 1: Config (Encrypted Secrets)

**Files:**
- Create: `lib/uniops/abilities/config.ex`
- Create: `test/uniops/abilities/config_test.exs`

Config stores secrets encrypted at rest in Mnesia. Uses AES-256-GCM with a key derived from a configurable secret. Scoped by environment name.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/abilities/config_test.exs`:

```elixir
defmodule Uniops.Abilities.ConfigTest do
  use ExUnit.Case, async: false

  alias Uniops.Abilities.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    :ok
  end

  describe "set/3 and get/2" do
    test "stores and retrieves a secret" do
      assert :ok = Config.set("prod", "api_key", "sk-secret-123")
      assert {:ok, "sk-secret-123"} = Config.get("prod", "api_key")
    end

    test "returns :not_found for missing key" do
      assert :not_found = Config.get("prod", "missing")
    end

    test "different environments are isolated" do
      Config.set("prod", "key", "prod-value")
      Config.set("staging", "key", "staging-value")
      assert {:ok, "prod-value"} = Config.get("prod", "key")
      assert {:ok, "staging-value"} = Config.get("staging", "key")
    end

    test "values are encrypted at rest" do
      Config.set("prod", "secret", "plaintext-value")
      # Read raw from Mnesia — value should NOT be plaintext
      {:atomic, [{_, _, raw}]} =
        :mnesia.transaction(fn ->
          :mnesia.read(Config.table_name(), {"prod", "secret"})
        end)
      refute raw == "plaintext-value"
      assert is_binary(raw)
    end

    test "overwrites existing key" do
      Config.set("prod", "key", "v1")
      Config.set("prod", "key", "v2")
      assert {:ok, "v2"} = Config.get("prod", "key")
    end
  end

  describe "delete/2" do
    test "removes a secret" do
      Config.set("prod", "temp", "val")
      assert :ok = Config.delete("prod", "temp")
      assert :not_found = Config.get("prod", "temp")
    end
  end

  describe "list/1" do
    test "returns keys for an environment" do
      Config.set("prod", "a", "1")
      Config.set("prod", "b", "2")
      Config.set("staging", "c", "3")
      keys = Config.list("prod")
      assert "a" in keys
      assert "b" in keys
      refute "c" in keys
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/abilities/config_test.exs`

- [ ] **Step 3: Implement Config**

Create `lib/uniops/abilities/config.ex`:

```elixir
defmodule Uniops.Abilities.Config do
  @moduledoc """
  Encrypted key-value store for secrets, scoped by environment.
  Values are encrypted with AES-256-GCM before storing in Mnesia.
  """

  @table :uniops_config

  def table_name, do: @table

  @doc "Stores an encrypted secret."
  def set(env, key, value) when is_binary(env) and is_binary(key) and is_binary(value) do
    ensure_table()
    encrypted = encrypt(value)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({@table, {env, key}, encrypted})
      end)

    :ok
  end

  @doc "Retrieves and decrypts a secret. Returns `{:ok, value}` or `:not_found`."
  def get(env, key) when is_binary(env) and is_binary(key) do
    ensure_table()

    {:atomic, result} =
      :mnesia.transaction(fn ->
        :mnesia.read(@table, {env, key})
      end)

    case result do
      [{@table, _, encrypted}] -> {:ok, decrypt(encrypted)}
      [] -> :not_found
    end
  end

  @doc "Deletes a secret."
  def delete(env, key) do
    ensure_table()

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.delete({@table, {env, key}})
      end)

    :ok
  end

  @doc "Lists all keys for an environment."
  def list(env) do
    ensure_table()

    {:atomic, records} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@table, {env, :_}, :_})
      end)

    Enum.map(records, fn {_, {_env, key}, _} -> key end)
  end

  defp ensure_table do
    case :mnesia.create_table(@table, [
           attributes: [:key, :value],
           type: :set,
           disc_copies: [node()]
         ]) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, @table}} -> :ok
    end
  end

  defp encryption_key do
    configured = Application.get_env(:uniops, :config_encryption_key, "uniops-default-key-change-me!")
    :crypto.hash(:sha256, configured)
  end

  defp encrypt(plaintext) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    iv <> tag <> ciphertext
  end

  defp decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = encryption_key()
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/uniops/abilities/config_test.exs`
Expected: 7 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add Config: encrypted key-value secrets with AES-256-GCM"
jj new
```

---

### Task 2: Blobs (Binary Object Storage)

**Files:**
- Create: `lib/uniops/abilities/blobs.ex`
- Create: `test/uniops/abilities/blobs_test.exs`

Blobs stores binary data on the filesystem, keyed by database + blob key. Supports write, read, delete, and prefix listing.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/abilities/blobs_test.exs`:

```elixir
defmodule Uniops.Abilities.BlobsTest do
  use ExUnit.Case, async: false

  alias Uniops.Abilities.Blobs

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_blobs_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "write/4 and read/3" do
    test "stores and retrieves binary data", %{dir: dir} do
      data = <<0, 1, 2, 255, 128>>
      assert :ok = Blobs.write(dir, "mydb", "images/photo.jpg", data)
      assert {:ok, ^data} = Blobs.read(dir, "mydb", "images/photo.jpg")
    end

    test "returns :not_found for missing blob", %{dir: dir} do
      assert :not_found = Blobs.read(dir, "mydb", "nope")
    end

    test "overwrites existing blob", %{dir: dir} do
      Blobs.write(dir, "mydb", "file", "v1")
      Blobs.write(dir, "mydb", "file", "v2")
      assert {:ok, "v2"} = Blobs.read(dir, "mydb", "file")
    end
  end

  describe "delete/3" do
    test "removes a blob", %{dir: dir} do
      Blobs.write(dir, "mydb", "temp", "data")
      assert :ok = Blobs.delete(dir, "mydb", "temp")
      assert :not_found = Blobs.read(dir, "mydb", "temp")
    end
  end

  describe "list/3" do
    test "lists blobs by prefix", %{dir: dir} do
      Blobs.write(dir, "mydb", "images/a.jpg", "a")
      Blobs.write(dir, "mydb", "images/b.jpg", "b")
      Blobs.write(dir, "mydb", "docs/readme.md", "c")

      keys = Blobs.list(dir, "mydb", "images/")
      assert "images/a.jpg" in keys
      assert "images/b.jpg" in keys
      refute "docs/readme.md" in keys
    end

    test "returns empty list for no matches", %{dir: dir} do
      assert [] = Blobs.list(dir, "mydb", "nothing/")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/abilities/blobs_test.exs`

- [ ] **Step 3: Implement Blobs**

Create `lib/uniops/abilities/blobs.ex`:

```elixir
defmodule Uniops.Abilities.Blobs do
  @moduledoc """
  Binary object storage on the filesystem.
  Blobs are stored at `<base_dir>/<db>/<key>` with directory creation on write.
  """

  @doc "Writes binary data to a blob."
  def write(base_dir, db, key, data) when is_binary(data) do
    path = blob_path(base_dir, db, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    :ok
  end

  @doc "Reads a blob. Returns `{:ok, data}` or `:not_found`."
  def read(base_dir, db, key) do
    path = blob_path(base_dir, db, key)

    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> :not_found
    end
  end

  @doc "Deletes a blob."
  def delete(base_dir, db, key) do
    path = blob_path(base_dir, db, key)
    File.rm(path)
    :ok
  end

  @doc "Lists blob keys matching a prefix."
  def list(base_dir, db, prefix) do
    db_dir = Path.join([base_dir, db])

    if File.dir?(db_dir) do
      db_dir
      |> list_files_recursive()
      |> Enum.map(fn path -> Path.relative_to(path, db_dir) end)
      |> Enum.filter(&String.starts_with?(&1, prefix))
    else
      []
    end
  end

  defp blob_path(base_dir, db, key) do
    Path.join([base_dir, db, key])
  end

  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          if File.dir?(path) do
            list_files_recursive(path)
          else
            [path]
          end
        end)

      {:error, _} ->
        []
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/uniops/abilities/blobs_test.exs`
Expected: 6 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add Blobs: filesystem-based binary object storage"
jj new
```

---

### Task 3: Scratch (Ephemeral In-Memory Cache)

**Files:**
- Create: `lib/uniops/abilities/scratch.ex`
- Create: `test/uniops/abilities/scratch_test.exs`
- Modify: `lib/uniops/application.ex`

Scratch is a node-local, ephemeral ETS cache. Resets on restart. Same GenServer+ETS pattern as HashCache.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/abilities/scratch_test.exs`:

```elixir
defmodule Uniops.Abilities.ScratchTest do
  use ExUnit.Case, async: false

  alias Uniops.Abilities.Scratch

  setup do
    cache = start_supervised!({Scratch, name: :test_scratch})
    %{cache: cache}
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a value", %{cache: c} do
      assert :ok = Scratch.put(c, "session:abc", "user-data")
      assert {:ok, "user-data"} = Scratch.get(c, "session:abc")
    end

    test "returns :not_found for missing key", %{cache: c} do
      assert :not_found = Scratch.get(c, "nope")
    end

    test "overwrites existing key", %{cache: c} do
      Scratch.put(c, "k", "v1")
      Scratch.put(c, "k", "v2")
      assert {:ok, "v2"} = Scratch.get(c, "k")
    end
  end

  describe "delete/2" do
    test "removes a key", %{cache: c} do
      Scratch.put(c, "temp", "val")
      assert :ok = Scratch.delete(c, "temp")
      assert :not_found = Scratch.get(c, "temp")
    end
  end

  describe "list/1" do
    test "returns all keys", %{cache: c} do
      Scratch.put(c, "a", "1")
      Scratch.put(c, "b", "2")
      keys = Scratch.list(c)
      assert "a" in keys
      assert "b" in keys
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/abilities/scratch_test.exs`

- [ ] **Step 3: Implement Scratch**

Create `lib/uniops/abilities/scratch.ex`:

```elixir
defmodule Uniops.Abilities.Scratch do
  @moduledoc """
  Ephemeral in-memory cache, node-local. Backed by ETS.
  Data is lost on node restart — use for temporary/session state only.
  """

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  def put(server \\ __MODULE__, key, value) do
    GenServer.call(server, {:put, key, value})
  end

  def get(server \\ __MODULE__, key) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  def delete(server \\ __MODULE__, key) do
    GenServer.call(server, {:delete, key})
  end

  def list(server \\ __MODULE__) do
    table = GenServer.call(server, :table)
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @impl true
  def init(name) do
    table = :ets.new(name, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(state.table, {key, value})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, state) do
    {:reply, state.table, state}
  end
end
```

- [ ] **Step 4: Add Scratch to supervision tree**

In `lib/uniops/application.ex`, add `Uniops.Abilities.Scratch` to `cluster_children`:

```elixir
  defp cluster_children do
    [
      Uniops.Cluster.HashCache,
      Uniops.Cluster.SyncServer,
      Uniops.Services.Registry,
      Uniops.Abilities.Scratch
    ]
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/uniops/abilities/scratch_test.exs`
Expected: 5 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
jj desc -m "Add Scratch: ephemeral in-memory cache"
jj new
```

---

### Task 4: Log (Structured Logging)

**Files:**
- Create: `lib/uniops/abilities/log.ex`
- Create: `test/uniops/abilities/log_test.exs`
- Modify: `lib/uniops/application.ex`

Log stores structured entries in an ETS ring buffer (fixed max size, oldest evicted). Also writes to Elixir's Logger.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/abilities/log_test.exs`:

```elixir
defmodule Uniops.Abilities.LogTest do
  use ExUnit.Case, async: false

  alias Uniops.Abilities.Log

  setup do
    log = start_supervised!({Log, name: :test_log, max_entries: 5})
    %{log: log}
  end

  describe "append/3 and recent/2" do
    test "stores and retrieves log entries", %{log: log} do
      Log.append(log, :info, "hello", %{service: "greeter"})
      entries = Log.recent(log, 10)
      assert length(entries) == 1
      assert hd(entries).message == "hello"
      assert hd(entries).level == :info
      assert hd(entries).metadata == %{service: "greeter"}
    end

    test "returns entries in reverse chronological order", %{log: log} do
      Log.append(log, :info, "first", %{})
      Log.append(log, :info, "second", %{})
      Log.append(log, :info, "third", %{})
      entries = Log.recent(log, 10)
      messages = Enum.map(entries, & &1.message)
      assert messages == ["third", "second", "first"]
    end

    test "ring buffer evicts oldest when full", %{log: log} do
      for i <- 1..7 do
        Log.append(log, :info, "msg-#{i}", %{})
      end

      entries = Log.recent(log, 10)
      assert length(entries) == 5
      messages = Enum.map(entries, & &1.message)
      assert "msg-7" in messages
      assert "msg-6" in messages
      refute "msg-1" in messages
    end
  end

  describe "convenience functions" do
    test "info/error/warn append with correct level", %{log: log} do
      Log.info(log, "info msg")
      Log.error(log, "error msg")
      Log.warn(log, "warn msg")

      entries = Log.recent(log, 10)
      levels = Enum.map(entries, & &1.level)
      assert :info in levels
      assert :error in levels
      assert :warn in levels
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/abilities/log_test.exs`

- [ ] **Step 3: Implement Log**

Create `lib/uniops/abilities/log.ex`:

```elixir
defmodule Uniops.Abilities.Log do
  @moduledoc """
  Structured logging with an ETS ring buffer.
  Stores the most recent N entries, evicting oldest when full.
  Also forwards to Elixir's Logger.
  """

  use GenServer

  require Logger

  defmodule Entry do
    @moduledoc false
    defstruct [:id, :level, :message, :metadata, :timestamp]
  end

  @default_max 1000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    max = Keyword.get(opts, :max_entries, @default_max)
    GenServer.start_link(__MODULE__, %{name: name, max: max}, name: name)
  end

  def append(server \\ __MODULE__, level, message, metadata \\ %{}) do
    GenServer.cast(server, {:append, level, message, metadata})
  end

  def info(server \\ __MODULE__, message, metadata \\ %{}), do: append(server, :info, message, metadata)
  def error(server \\ __MODULE__, message, metadata \\ %{}), do: append(server, :error, message, metadata)
  def warn(server \\ __MODULE__, message, metadata \\ %{}), do: append(server, :warn, message, metadata)

  @doc "Returns the most recent `n` entries, newest first."
  def recent(server \\ __MODULE__, n) do
    GenServer.call(server, {:recent, n})
  end

  @impl true
  def init(%{name: name, max: max}) do
    table = :ets.new(name, [:ordered_set, :public])
    {:ok, %{table: table, max: max, counter: 0}}
  end

  @impl true
  def handle_cast({:append, level, message, metadata}, state) do
    counter = state.counter + 1

    entry = %Entry{
      id: counter,
      level: level,
      message: message,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(state.table, {counter, entry})

    # Forward to Logger
    case level do
      :info -> Logger.info(message, Map.to_list(metadata))
      :error -> Logger.error(message, Map.to_list(metadata))
      :warn -> Logger.warning(message, Map.to_list(metadata))
      _ -> Logger.debug(message, Map.to_list(metadata))
    end

    # Evict oldest if over max
    state =
      if counter > state.max do
        evict_key = counter - state.max
        :ets.delete(state.table, evict_key)
        state
      else
        state
      end

    {:noreply, %{state | counter: counter}}
  end

  @impl true
  def handle_call({:recent, n}, _from, state) do
    all = :ets.tab2list(state.table)

    entries =
      all
      |> Enum.sort_by(fn {id, _} -> id end, :desc)
      |> Enum.take(n)
      |> Enum.map(fn {_, entry} -> entry end)

    {:reply, entries, state}
  end
end
```

- [ ] **Step 4: Add Log to supervision tree**

In `lib/uniops/application.ex`, add `Uniops.Abilities.Log` to `cluster_children`:

```elixir
  defp cluster_children do
    [
      Uniops.Cluster.HashCache,
      Uniops.Cluster.SyncServer,
      Uniops.Services.Registry,
      Uniops.Abilities.Scratch,
      Uniops.Abilities.Log
    ]
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/uniops/abilities/log_test.exs`
Expected: 4 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
jj desc -m "Add Log: structured logging with ETS ring buffer"
jj new
```

---

### Task 5: HTTP API for All Four Abilities

**Files:**
- Create: `lib/uniops/api/config_controller.ex`
- Create: `lib/uniops/api/blobs_controller.ex`
- Create: `lib/uniops/api/scratch_controller.ex`
- Create: `lib/uniops/api/log_controller.ex`
- Modify: `lib/uniops/api/router.ex`
- Create: `test/uniops/api/abilities_api_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/api/abilities_api_test.exs`:

```elixir
defmodule Uniops.API.AbilitiesAPITest do
  use ExUnit.Case, async: false
  use Plug.Test

  setup_all do
    dir = Path.join(System.tmp_dir!(), "uniops_abilities_api_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    Application.put_env(:uniops, :blobs_dir, Path.join(dir, "blobs"))
    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    :ok
  end

  defp call(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> Uniops.API.Router.call(Uniops.API.Router.init([]))
  end

  # --- Config ---

  describe "Config API" do
    test "set and get a secret" do
      conn = conn(:post, "/config/prod/api_key",
        Jason.encode!(%{value: "sk-123"})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/config/prod/api_key") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["value"] == "sk-123"
    end

    test "get missing returns 404" do
      conn = conn(:get, "/config/prod/nope") |> call()
      assert conn.status == 404
    end

    test "list keys" do
      conn(:post, "/config/listenv/k1", Jason.encode!(%{value: "v1"})) |> call()
      conn(:post, "/config/listenv/k2", Jason.encode!(%{value: "v2"})) |> call()
      conn = conn(:get, "/config/listenv") |> call()
      assert conn.status == 200
      keys = Jason.decode!(conn.resp_body)["keys"]
      assert "k1" in keys
      assert "k2" in keys
    end
  end

  # --- Blobs ---

  describe "Blobs API" do
    test "write and read a blob" do
      conn = conn(:post, "/blobs/mydb/files/test.txt",
        Jason.encode!(%{data: Base.encode64("hello blob")})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/blobs/mydb/files/test.txt") |> call()
      assert conn.status == 200
      assert Base.decode64!(Jason.decode!(conn.resp_body)["data"]) == "hello blob"
    end

    test "read missing returns 404" do
      conn = conn(:get, "/blobs/mydb/nope") |> call()
      assert conn.status == 404
    end

    test "list by prefix" do
      conn(:post, "/blobs/mydb/imgs/a.jpg", Jason.encode!(%{data: Base.encode64("a")})) |> call()
      conn(:post, "/blobs/mydb/imgs/b.jpg", Jason.encode!(%{data: Base.encode64("b")})) |> call()
      conn = conn(:post, "/blobs/mydb/list", Jason.encode!(%{prefix: "imgs/"})) |> call()
      assert conn.status == 200
      keys = Jason.decode!(conn.resp_body)["keys"]
      assert "imgs/a.jpg" in keys
    end
  end

  # --- Scratch ---

  describe "Scratch API" do
    test "put and get" do
      conn = conn(:post, "/scratch/mykey",
        Jason.encode!(%{value: "cached"})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/scratch/mykey") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["value"] == "cached"
    end

    test "get missing returns 404" do
      conn = conn(:get, "/scratch/nope") |> call()
      assert conn.status == 404
    end
  end

  # --- Log ---

  describe "Log API" do
    test "append and get recent" do
      conn = conn(:post, "/log",
        Jason.encode!(%{level: "info", message: "test log", metadata: %{svc: "test"}})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/log/recent/10") |> call()
      assert conn.status == 200
      entries = Jason.decode!(conn.resp_body)["entries"]
      assert length(entries) >= 1
      assert hd(entries)["message"] == "test log"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/uniops/api/abilities_api_test.exs`

- [ ] **Step 3: Implement all four controllers**

Create `lib/uniops/api/config_controller.ex`:

```elixir
defmodule Uniops.API.ConfigController do
  @moduledoc false
  alias Uniops.API.Json
  alias Uniops.Abilities.Config

  def set(conn, env, key) do
    {:ok, %{"value" => value}} = Json.read_json(conn)
    :ok = Config.set(env, key, value)
    Json.send_json(conn, 200, %{env: env, key: key})
  end

  def get(conn, env, key) do
    case Config.get(env, key) do
      {:ok, value} -> Json.send_json(conn, 200, %{env: env, key: key, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  def list(conn, env) do
    keys = Config.list(env)
    Json.send_json(conn, 200, %{env: env, keys: keys})
  end
end
```

Create `lib/uniops/api/blobs_controller.ex`:

```elixir
defmodule Uniops.API.BlobsController do
  @moduledoc false
  alias Uniops.API.Json
  alias Uniops.Abilities.Blobs

  defp blobs_dir do
    Application.get_env(:uniops, :blobs_dir, Path.join(System.tmp_dir!(), "uniops_blobs"))
  end

  def write(conn, db, key) do
    {:ok, %{"data" => b64_data}} = Json.read_json(conn)
    data = Base.decode64!(b64_data)
    :ok = Blobs.write(blobs_dir(), db, key, data)
    Json.send_json(conn, 200, %{db: db, key: key})
  end

  def read(conn, db, key) do
    case Blobs.read(blobs_dir(), db, key) do
      {:ok, data} -> Json.send_json(conn, 200, %{db: db, key: key, data: Base.encode64(data)})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  def list(conn, db) do
    {:ok, %{"prefix" => prefix}} = Json.read_json(conn)
    keys = Blobs.list(blobs_dir(), db, prefix)
    Json.send_json(conn, 200, %{db: db, keys: keys})
  end
end
```

Create `lib/uniops/api/scratch_controller.ex`:

```elixir
defmodule Uniops.API.ScratchController do
  @moduledoc false
  alias Uniops.API.Json
  alias Uniops.Abilities.Scratch

  def put(conn, key) do
    {:ok, %{"value" => value}} = Json.read_json(conn)
    :ok = Scratch.put(key, value)
    Json.send_json(conn, 200, %{key: key})
  end

  def get(conn, key) do
    case Scratch.get(key) do
      {:ok, value} -> Json.send_json(conn, 200, %{key: key, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end
end
```

Create `lib/uniops/api/log_controller.ex`:

```elixir
defmodule Uniops.API.LogController do
  @moduledoc false
  alias Uniops.API.Json
  alias Uniops.Abilities.Log

  def append(conn) do
    {:ok, %{"level" => level, "message" => message} = body} = Json.read_json(conn)
    metadata = Map.get(body, "metadata", %{})
    Log.append(String.to_existing_atom(level), message, metadata)
    Json.send_json(conn, 200, %{status: "logged"})
  end

  def recent(conn, n) do
    entries =
      Log.recent(String.to_integer(n))
      |> Enum.map(fn e ->
        %{
          level: Atom.to_string(e.level),
          message: e.message,
          metadata: e.metadata,
          timestamp: DateTime.to_iso8601(e.timestamp)
        }
      end)

    Json.send_json(conn, 200, %{entries: entries})
  end
end
```

- [ ] **Step 4: Add routes to the router**

Add these routes to `lib/uniops/api/router.ex` before the `match _` catch-all:

```elixir
  # Config routes
  post "/config/:env/:key" do
    Uniops.API.ConfigController.set(conn, env, key)
  end

  get "/config/:env/:key" do
    Uniops.API.ConfigController.get(conn, env, key)
  end

  get "/config/:env" do
    Uniops.API.ConfigController.list(conn, env)
  end

  # Blobs routes
  post "/blobs/:db/*key" do
    key_str = Enum.join(key, "/")
    Uniops.API.BlobsController.write(conn, db, key_str)
  end

  get "/blobs/:db/*key" do
    key_str = Enum.join(key, "/")
    Uniops.API.BlobsController.read(conn, db, key_str)
  end

  post "/blobs/:db/list" do
    Uniops.API.BlobsController.list(conn, db)
  end

  # Scratch routes
  post "/scratch/:key" do
    Uniops.API.ScratchController.put(conn, key)
  end

  get "/scratch/:key" do
    Uniops.API.ScratchController.get(conn, key)
  end

  # Log routes
  post "/log" do
    Uniops.API.LogController.append(conn)
  end

  get "/log/recent/:n" do
    Uniops.API.LogController.recent(conn, n)
  end
```

**IMPORTANT:** The `/blobs/:db/list` route must come BEFORE the `/blobs/:db/*key` route, otherwise `*key` will swallow `list`. Alternatively, use a different URL like `POST /blobs/:db/_list`. Check Plug.Router's matching order — routes are matched in definition order, so define `/blobs/:db/list` first.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/uniops/api/abilities_api_test.exs`
Expected: 8 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
jj desc -m "Add HTTP API for Config, Blobs, Scratch, and Log abilities"
jj new
```

---

### Task 6: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: All tests pass (~110 total)

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation

- [ ] **Step 3: Commit final state**

```bash
jj desc -m "Complete Plan 6: Config, Blobs, Scratch, and Log abilities"
```

---

## What This Plan Produces

1. **Config** — AES-256-GCM encrypted secrets in Mnesia, scoped by environment
2. **Blobs** — Filesystem-based binary object storage with prefix listing
3. **Scratch** — Node-local ephemeral ETS cache (lost on restart)
4. **Log** — Structured logging with ETS ring buffer + Elixir Logger forwarding
5. **HTTP API** — All four abilities accessible via REST endpoints

This completes the full Uniops ability set. The project now provides open-source equivalents for every Unison Cloud ability: Storage, Remote, Services, Config, Blobs, Scratch, and Log.
