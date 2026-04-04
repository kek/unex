# Storage Ability Handlers (Mnesia-Backed, Single Node) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a durable key-value storage system backed by Mnesia, exposed via a JSON HTTP API that Unison programs can call using the `Http` ability, implementing OrderedTable, Cell, and transactional semantics on a single BEAM node.

**Architecture:** Mnesia (built into OTP) provides ordered_set tables for sorted key-value storage, set tables for cells, and native ACID transactions. A Plug-based HTTP API server runs inside the OTP application, exposing CRUD + range-scan endpoints. Unison programs use `@unison/http` to call this API, giving them durable storage without the proprietary Cloud runtime. All data is JSON-encoded at the HTTP boundary.

**Tech Stack:** Elixir 1.19 / OTP 28, Mnesia (built-in), Plug + Bandit (HTTP server), Jason (JSON), ExUnit

---

## Scope Note

This is Plan 2 of 6 for the Uniops project. It covers **only** single-node storage (OrderedTable, Cell, Transaction) with an HTTP API. It does **not** cover:

- `Table` (basic hash KV) — trivially addable later, same pattern as OrderedTable
- `Blobs` — binary object storage, deferred to Plan 6
- `Config` / `Scratch` / `Log` — deferred to Plan 6
- Distribution / replication — deferred to Plan 3
- Matching exact Unison Cloud Storage types — we define our own compatible API

## Prerequisites

- Plan 1 completed: Elixir OTP application with UCM integration working
- Elixir 1.19+ and OTP 28+ on PATH
- UCM 1.1.1 on PATH

## File Structure

```
lib/
  uniops/
    application.ex                    # Modify: add Mnesia init + HTTP server to supervision tree
    storage/
      schema.ex                       # Mnesia schema initialization at application startup
      database.ex                     # Database (namespace) management — create, list, exists?
      ordered_table.ex                # Sorted key-value: write, read, delete, scan (range queries)
      cell.ex                         # Single durable value: read, write
      transaction.ex                  # Atomic multi-operation batches via Mnesia transactions
    api/
      router.ex                       # Plug router: dispatches HTTP requests to handlers
      json.ex                         # JSON request/response helpers
      database_controller.ex          # HTTP handlers for /databases endpoints
      ordered_table_controller.ex     # HTTP handlers for /databases/:db/tables/:table endpoints
      cell_controller.ex              # HTTP handlers for /databases/:db/cells/:name endpoints
      transaction_controller.ex       # HTTP handler for /databases/:db/tx endpoint
config/
  config.exs                          # Modify: add storage + API config
mix.exs                               # Modify: add deps (plug, bandit, jason)
test/
  uniops/
    storage/
      database_test.exs               # Database CRUD tests
      ordered_table_test.exs          # OrderedTable operation tests
      cell_test.exs                   # Cell operation tests
      transaction_test.exs            # Transaction atomicity tests
    api/
      router_test.exs                 # HTTP API integration tests
  integration/
    unison_storage_test.exs           # End-to-end: Unison code calls HTTP API via @unison/http
```

---

### Task 1: Add Dependencies

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`

- [ ] **Step 1: Add plug, bandit, and jason to mix.exs**

Edit `mix.exs`, replace the `deps` function:

```elixir
  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"}
    ]
  end
```

- [ ] **Step 2: Add :mnesia to extra_applications**

In `mix.exs`, update the `application` function:

```elixir
  def application do
    [
      extra_applications: [:logger, :mnesia],
      mod: {Uniops.Application, []}
    ]
  end
```

- [ ] **Step 3: Add storage and API config**

Append to `config/config.exs`:

```elixir
config :uniops,
  api_port: String.to_integer(System.get_env("UNIOPS_API_PORT") || "4040"),
  mnesia_dir: System.get_env("UNIOPS_MNESIA_DIR") || Path.join(System.tmp_dir!(), "uniops_mnesia")
```

- [ ] **Step 4: Install dependencies**

Run: `mix deps.get`
Expected: Dependencies resolved and fetched

- [ ] **Step 5: Verify compilation**

Run: `mix compile`
Expected: Compiles with no errors

- [ ] **Step 6: Commit**

```bash
jj desc -m "Add plug, bandit, jason deps for storage HTTP API"
jj new
```

---

### Task 2: Mnesia Schema Initialization

**Files:**
- Create: `lib/uniops/storage/schema.ex`
- Create: `test/uniops/storage/schema_test.exs`
- Modify: `lib/uniops/application.ex`

Mnesia needs a schema created before tables can be used. We create the schema on disk at startup, and manage a registry table that tracks which databases/tables exist.

- [ ] **Step 1: Write the failing test**

Create `test/uniops/storage/schema_test.exs`:

```elixir
defmodule Uniops.Storage.SchemaTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_mnesia_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "init/1" do
    test "initializes Mnesia with a schema on disk", %{dir: dir} do
      assert :ok = Uniops.Storage.Schema.init(dir)
      assert :mnesia.system_info(:is_running) == :yes
      assert :mnesia.system_info(:use_dir) == true
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/uniops/storage/schema_test.exs`
Expected: FAIL — `Uniops.Storage.Schema` not found

- [ ] **Step 3: Implement schema initialization**

Create `lib/uniops/storage/schema.ex`:

```elixir
defmodule Uniops.Storage.Schema do
  @moduledoc """
  Initializes Mnesia schema and core registry tables at application startup.
  """

  @registry_table :uniops_registry

  @doc """
  Initializes Mnesia with disk-based schema at the given directory.
  Creates the registry table if it doesn't exist.
  """
  def init(dir) do
    :mnesia.stop()
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))
    ensure_schema()
    :mnesia.start()
    ensure_registry()
    :ok
  end

  @doc """
  Returns the registry table name.
  """
  def registry_table, do: @registry_table

  defp ensure_schema do
    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
    end
  end

  defp ensure_registry do
    case :mnesia.create_table(@registry_table, [
           attributes: [:key, :value],
           disc_copies: [node()]
         ]) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, @registry_table}} -> :ok
    end

    :mnesia.wait_for_tables([@registry_table], 5_000)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/uniops/storage/schema_test.exs`
Expected: 1 test, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add Mnesia schema initialization for storage"
jj new
```

---

### Task 3: Database Management

**Files:**
- Create: `lib/uniops/storage/database.ex`
- Create: `test/uniops/storage/database_test.exs`

A Database is a namespace that groups tables and cells. Creating a database registers it in the Mnesia registry. It's a lightweight logical container.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/storage/database_test.exs`:

```elixir
defmodule Uniops.Storage.DatabaseTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_db_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    :ok
  end

  describe "create/1" do
    test "creates a database and returns :ok" do
      assert :ok = Uniops.Storage.Database.create("mydb")
    end

    test "is idempotent" do
      assert :ok = Uniops.Storage.Database.create("mydb")
      assert :ok = Uniops.Storage.Database.create("mydb")
    end
  end

  describe "exists?/1" do
    test "returns false for nonexistent database" do
      refute Uniops.Storage.Database.exists?("nope")
    end

    test "returns true after creation" do
      Uniops.Storage.Database.create("mydb")
      assert Uniops.Storage.Database.exists?("mydb")
    end
  end

  describe "list/0" do
    test "returns list of created databases" do
      Uniops.Storage.Database.create("alpha")
      Uniops.Storage.Database.create("beta")
      dbs = Uniops.Storage.Database.list()
      assert "alpha" in dbs
      assert "beta" in dbs
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/storage/database_test.exs`
Expected: FAIL — `Uniops.Storage.Database` not found

- [ ] **Step 3: Implement database management**

Create `lib/uniops/storage/database.ex`:

```elixir
defmodule Uniops.Storage.Database do
  @moduledoc """
  Manages logical databases (namespaces for tables and cells).
  Databases are registered in the Mnesia registry table.
  """

  @doc """
  Creates a database. Idempotent — returns :ok if already exists.
  """
  def create(name) when is_binary(name) do
    :mnesia.transaction(fn ->
      :mnesia.write({Uniops.Storage.Schema.registry_table(), {:database, name}, true})
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns true if the database exists.
  """
  def exists?(name) when is_binary(name) do
    case :mnesia.transaction(fn ->
           :mnesia.read(Uniops.Storage.Schema.registry_table(), {:database, name})
         end) do
      {:atomic, [_]} -> true
      {:atomic, []} -> false
    end
  end

  @doc """
  Returns a list of all database names.
  """
  def list do
    {:atomic, records} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({Uniops.Storage.Schema.registry_table(), {:database, :_}, :_})
      end)

    Enum.map(records, fn {_, {:database, name}, _} -> name end)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/storage/database_test.exs`
Expected: 4 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add database (namespace) management for storage"
jj new
```

---

### Task 4: OrderedTable

**Files:**
- Create: `lib/uniops/storage/ordered_table.ex`
- Create: `test/uniops/storage/ordered_table_test.exs`

OrderedTable is the primary storage primitive — a sorted key-value store backed by a Mnesia `ordered_set` table. Supports write, read, delete, and range scan.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/storage/ordered_table_test.exs`:

```elixir
defmodule Uniops.Storage.OrderedTableTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_ot_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    Uniops.Storage.Database.create("testdb")
    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    %{db: "testdb"}
  end

  describe "ensure/2" do
    test "creates an ordered table within a database", %{db: db} do
      assert :ok = Uniops.Storage.OrderedTable.ensure(db, "users")
    end

    test "is idempotent", %{db: db} do
      assert :ok = Uniops.Storage.OrderedTable.ensure(db, "users")
      assert :ok = Uniops.Storage.OrderedTable.ensure(db, "users")
    end
  end

  describe "write/4 and read/3" do
    test "writes and reads a key-value pair", %{db: db} do
      Uniops.Storage.OrderedTable.ensure(db, "users")
      assert :ok = Uniops.Storage.OrderedTable.write(db, "users", "alice", "{'name':'Alice'}")
      assert {:ok, "{'name':'Alice'}"} = Uniops.Storage.OrderedTable.read(db, "users", "alice")
    end

    test "returns :not_found for missing key", %{db: db} do
      Uniops.Storage.OrderedTable.ensure(db, "users")
      assert :not_found = Uniops.Storage.OrderedTable.read(db, "users", "nobody")
    end

    test "overwrites existing key", %{db: db} do
      Uniops.Storage.OrderedTable.ensure(db, "users")
      Uniops.Storage.OrderedTable.write(db, "users", "alice", "v1")
      Uniops.Storage.OrderedTable.write(db, "users", "alice", "v2")
      assert {:ok, "v2"} = Uniops.Storage.OrderedTable.read(db, "users", "alice")
    end
  end

  describe "delete/3" do
    test "removes a key", %{db: db} do
      Uniops.Storage.OrderedTable.ensure(db, "users")
      Uniops.Storage.OrderedTable.write(db, "users", "alice", "data")
      assert :ok = Uniops.Storage.OrderedTable.delete(db, "users", "alice")
      assert :not_found = Uniops.Storage.OrderedTable.read(db, "users", "alice")
    end
  end

  describe "scan/4" do
    test "returns key-value pairs in sorted order within a range", %{db: db} do
      Uniops.Storage.OrderedTable.ensure(db, "scores")
      Uniops.Storage.OrderedTable.write(db, "scores", "alice", "90")
      Uniops.Storage.OrderedTable.write(db, "scores", "bob", "85")
      Uniops.Storage.OrderedTable.write(db, "scores", "carol", "95")
      Uniops.Storage.OrderedTable.write(db, "scores", "dave", "88")

      result = Uniops.Storage.OrderedTable.scan(db, "scores", "bob", "dave")
      assert result == [{"bob", "85"}, {"carol", "95"}, {"dave", "88"}]
    end

    test "returns empty list when range has no matches", %{db: db} do
      Uniops.Storage.OrderedTable.ensure(db, "empty")
      assert [] = Uniops.Storage.OrderedTable.scan(db, "empty", "a", "z")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/storage/ordered_table_test.exs`
Expected: FAIL — `Uniops.Storage.OrderedTable` not found

- [ ] **Step 3: Implement OrderedTable**

Create `lib/uniops/storage/ordered_table.ex`:

```elixir
defmodule Uniops.Storage.OrderedTable do
  @moduledoc """
  Sorted key-value store backed by a Mnesia ordered_set table.
  Keys are sorted lexicographically, enabling range scans.
  """

  @doc """
  Ensures an ordered table exists in the given database. Idempotent.
  """
  def ensure(db, table) when is_binary(db) and is_binary(table) do
    tab = table_name(db, table)

    case :mnesia.create_table(tab, [
           attributes: [:key, :value],
           type: :ordered_set,
           disc_copies: [node()]
         ]) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^tab}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes a key-value pair. Overwrites if the key exists.
  """
  def write(db, table, key, value) do
    tab = table_name(db, table)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({tab, key, value})
      end)

    :ok
  end

  @doc """
  Reads the value for a key. Returns `{:ok, value}` or `:not_found`.
  """
  def read(db, table, key) do
    tab = table_name(db, table)

    {:atomic, result} =
      :mnesia.transaction(fn ->
        :mnesia.read(tab, key)
      end)

    case result do
      [{^tab, ^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @doc """
  Deletes a key.
  """
  def delete(db, table, key) do
    tab = table_name(db, table)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.delete({tab, key})
      end)

    :ok
  end

  @doc """
  Scans keys in the range [from, to] inclusive, returning `[{key, value}]` sorted.
  """
  def scan(db, table, from, to) do
    tab = table_name(db, table)

    {:atomic, results} =
      :mnesia.transaction(fn ->
        scan_range(tab, from, to, [])
      end)

    Enum.reverse(results)
  end

  defp scan_range(tab, from, to, acc) do
    case :mnesia.select(tab, [{{tab, :"$1", :"$2"}, [{:>=, :"$1", from}, {:"=<", :"$1", to}], [{{:"$1", :"$2"}}]}]) do
      results when is_list(results) -> Enum.sort_by(results, &elem(&1, 0))
    end
  end

  @doc """
  Returns the Mnesia table atom for a db+table combination.
  """
  def table_name(db, table) do
    :"uniops_ot_#{db}_#{table}"
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/storage/ordered_table_test.exs`
Expected: 7 tests, 0 failures

Note: The `scan_range` implementation uses `mnesia:select` with match specifications for range queries. If the match spec syntax causes issues, an alternative is to iterate with `mnesia:next` starting from `from` until past `to`. Debug and adjust if needed.

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add OrderedTable: sorted key-value store with range scans"
jj new
```

---

### Task 5: Cell

**Files:**
- Create: `lib/uniops/storage/cell.ex`
- Create: `test/uniops/storage/cell_test.exs`

A Cell stores a single durable value per name within a database. Backed by a Mnesia set table shared across all cells in a database.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/storage/cell_test.exs`:

```elixir
defmodule Uniops.Storage.CellTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_cell_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    Uniops.Storage.Database.create("testdb")
    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    %{db: "testdb"}
  end

  describe "write/3 and read/2" do
    test "writes and reads a cell value", %{db: db} do
      assert :ok = Uniops.Storage.Cell.write(db, "counter", "42")
      assert {:ok, "42"} = Uniops.Storage.Cell.read(db, "counter")
    end

    test "returns :not_found for unset cell", %{db: db} do
      assert :not_found = Uniops.Storage.Cell.read(db, "missing")
    end

    test "overwrites existing cell value", %{db: db} do
      Uniops.Storage.Cell.write(db, "counter", "1")
      Uniops.Storage.Cell.write(db, "counter", "2")
      assert {:ok, "2"} = Uniops.Storage.Cell.read(db, "counter")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/storage/cell_test.exs`
Expected: FAIL — `Uniops.Storage.Cell` not found

- [ ] **Step 3: Implement Cell**

Create `lib/uniops/storage/cell.ex`:

```elixir
defmodule Uniops.Storage.Cell do
  @moduledoc """
  Single durable value store. Each cell is identified by a database + name.
  All cells in a database share one Mnesia table.
  """

  @doc """
  Writes a value to a named cell. Creates the backing table if needed.
  """
  def write(db, name, value) when is_binary(db) and is_binary(name) do
    tab = ensure_table(db)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({tab, name, value})
      end)

    :ok
  end

  @doc """
  Reads the value of a named cell. Returns `{:ok, value}` or `:not_found`.
  """
  def read(db, name) when is_binary(db) and is_binary(name) do
    tab = ensure_table(db)

    {:atomic, result} =
      :mnesia.transaction(fn ->
        :mnesia.read(tab, name)
      end)

    case result do
      [{^tab, ^name, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  defp ensure_table(db) do
    tab = table_name(db)

    case :mnesia.create_table(tab, [
           attributes: [:name, :value],
           type: :set,
           disc_copies: [node()]
         ]) do
      {:atomic, :ok} -> tab
      {:aborted, {:already_exists, ^tab}} -> tab
    end
  end

  @doc false
  def table_name(db), do: :"uniops_cells_#{db}"
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/storage/cell_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add Cell: single durable value store"
jj new
```

---

### Task 6: Transactions

**Files:**
- Create: `lib/uniops/storage/transaction.ex`
- Create: `test/uniops/storage/transaction_test.exs`

Transactions execute a batch of storage operations atomically — all succeed or all fail. This wraps multiple OrderedTable and Cell operations in a single Mnesia transaction.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/storage/transaction_test.exs`:

```elixir
defmodule Uniops.Storage.TransactionTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_tx_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    Uniops.Storage.Database.create("testdb")
    Uniops.Storage.OrderedTable.ensure("testdb", "accounts")
    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    %{db: "testdb"}
  end

  describe "execute/2" do
    test "commits all operations atomically", %{db: db} do
      ops = [
        {:write_table, "accounts", "alice", "100"},
        {:write_table, "accounts", "bob", "200"},
        {:write_cell, "total", "300"}
      ]

      assert :ok = Uniops.Storage.Transaction.execute(db, ops)
      assert {:ok, "100"} = Uniops.Storage.OrderedTable.read(db, "accounts", "alice")
      assert {:ok, "200"} = Uniops.Storage.OrderedTable.read(db, "accounts", "bob")
      assert {:ok, "300"} = Uniops.Storage.Cell.read(db, "total")
    end

    test "rolls back all operations on failure", %{db: db} do
      # Write initial value
      Uniops.Storage.OrderedTable.write(db, "accounts", "alice", "100")

      ops = [
        {:write_table, "accounts", "alice", "999"},
        {:delete_table, "accounts", "alice"},
        {:invalid_op, "bad"}
      ]

      assert {:error, _reason} = Uniops.Storage.Transaction.execute(db, ops)
      # alice should still have original value — transaction rolled back
      assert {:ok, "100"} = Uniops.Storage.OrderedTable.read(db, "accounts", "alice")
    end

    test "supports mixed table and cell operations", %{db: db} do
      ops = [
        {:write_table, "accounts", "carol", "50"},
        {:write_cell, "last_updated", "2026-04-04"},
        {:delete_table, "accounts", "carol"}
      ]

      assert :ok = Uniops.Storage.Transaction.execute(db, ops)
      assert :not_found = Uniops.Storage.OrderedTable.read(db, "accounts", "carol")
      assert {:ok, "2026-04-04"} = Uniops.Storage.Cell.read(db, "last_updated")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/storage/transaction_test.exs`
Expected: FAIL — `Uniops.Storage.Transaction` not found

- [ ] **Step 3: Implement Transaction**

Create `lib/uniops/storage/transaction.ex`:

```elixir
defmodule Uniops.Storage.Transaction do
  @moduledoc """
  Executes a batch of storage operations atomically using Mnesia transactions.
  All operations succeed together or all are rolled back.
  """

  @doc """
  Executes a list of operations atomically within the given database.

  Supported operations:
    - `{:write_table, table, key, value}` — write to an OrderedTable
    - `{:read_table, table, key}` — read from an OrderedTable (result discarded in batch)
    - `{:delete_table, table, key}` — delete from an OrderedTable
    - `{:write_cell, name, value}` — write to a Cell
    - `{:read_cell, name}` — read a Cell (result discarded in batch)

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def execute(db, ops) when is_binary(db) and is_list(ops) do
    result =
      :mnesia.transaction(fn ->
        Enum.each(ops, fn op -> execute_op(db, op) end)
      end)

    case result do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp execute_op(db, {:write_table, table, key, value}) do
    tab = Uniops.Storage.OrderedTable.table_name(db, table)
    :mnesia.write({tab, key, value})
  end

  defp execute_op(db, {:read_table, table, key}) do
    tab = Uniops.Storage.OrderedTable.table_name(db, table)
    :mnesia.read(tab, key)
  end

  defp execute_op(db, {:delete_table, table, key}) do
    tab = Uniops.Storage.OrderedTable.table_name(db, table)
    :mnesia.delete({tab, key})
  end

  defp execute_op(db, {:write_cell, name, value}) do
    tab = Uniops.Storage.Cell.table_name(db)
    :mnesia.write({tab, name, value})
  end

  defp execute_op(db, {:read_cell, name}) do
    tab = Uniops.Storage.Cell.table_name(db)
    :mnesia.read(tab, name)
  end

  defp execute_op(_db, op) do
    :mnesia.abort({:unknown_operation, op})
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/storage/transaction_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add transactional batch operations for storage"
jj new
```

---

### Task 7: JSON Request/Response Helpers

**Files:**
- Create: `lib/uniops/api/json.ex`
- Create: `test/uniops/api/json_test.exs`

Shared helpers for reading JSON request bodies and sending JSON responses in Plug handlers.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/api/json_test.exs`:

```elixir
defmodule Uniops.API.JsonTest do
  use ExUnit.Case, async: true
  use Plug.Test

  describe "send_json/3" do
    test "sends a JSON response with correct content type" do
      conn = conn(:get, "/test")
      conn = Uniops.API.Json.send_json(conn, 200, %{status: "ok"})
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end
  end

  describe "read_json/1" do
    test "parses JSON body from a connection" do
      conn = conn(:post, "/test", Jason.encode!(%{key: "val"}))
      conn = put_req_header(conn, "content-type", "application/json")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      assert {:ok, %{"key" => "val"}} = Uniops.API.Json.read_json(conn)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/api/json_test.exs`
Expected: FAIL — `Uniops.API.Json` not found

- [ ] **Step 3: Implement JSON helpers**

Create `lib/uniops/api/json.ex`:

```elixir
defmodule Uniops.API.Json do
  @moduledoc """
  Shared JSON request/response helpers for Plug controllers.
  """

  import Plug.Conn

  @doc """
  Sends a JSON response with the given status and body (map or list).
  """
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc """
  Reads the parsed JSON body from the connection.
  Requires Plug.Parsers to have already parsed the body.
  """
  def read_json(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:error, :not_parsed}
      params when is_map(params) -> {:ok, params}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/api/json_test.exs`
Expected: 2 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add JSON request/response helpers for HTTP API"
jj new
```

---

### Task 8: HTTP API Router and Controllers

**Files:**
- Create: `lib/uniops/api/router.ex`
- Create: `lib/uniops/api/database_controller.ex`
- Create: `lib/uniops/api/ordered_table_controller.ex`
- Create: `lib/uniops/api/cell_controller.ex`
- Create: `lib/uniops/api/transaction_controller.ex`
- Create: `test/uniops/api/router_test.exs`
- Modify: `lib/uniops/application.ex`

The HTTP API router dispatches requests to controllers. The API endpoints are:

```
POST   /databases                              → create database
GET    /databases                              → list databases
POST   /databases/:db/tables/:table            → ensure table
POST   /databases/:db/tables/:table/write      → write key-value
GET    /databases/:db/tables/:table/read/:key  → read key
DELETE /databases/:db/tables/:table/delete/:key → delete key
POST   /databases/:db/tables/:table/scan       → range scan
POST   /databases/:db/cells/:name/write        → write cell
GET    /databases/:db/cells/:name/read         → read cell
POST   /databases/:db/tx                       → transactional batch
GET    /health                                 → health check
```

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/api/router_test.exs`:

```elixir
defmodule Uniops.API.RouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  setup_all do
    dir = Path.join(System.tmp_dir!(), "uniops_api_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
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

  describe "GET /health" do
    test "returns 200 ok" do
      conn = conn(:get, "/health") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end
  end

  describe "databases" do
    test "create and list databases" do
      conn = conn(:post, "/databases", Jason.encode!(%{name: "apitest"})) |> call()
      assert conn.status == 201

      conn = conn(:get, "/databases") |> call()
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert "apitest" in body["databases"]
    end
  end

  describe "ordered table CRUD" do
    test "ensure, write, read, delete, scan" do
      conn(:post, "/databases", Jason.encode!(%{name: "crud"})) |> call()

      # Ensure table
      conn = conn(:post, "/databases/crud/tables/items") |> call()
      assert conn.status == 201

      # Write
      conn = conn(:post, "/databases/crud/tables/items/write",
        Jason.encode!(%{key: "a", value: "1"})) |> call()
      assert conn.status == 200

      conn = conn(:post, "/databases/crud/tables/items/write",
        Jason.encode!(%{key: "b", value: "2"})) |> call()
      assert conn.status == 200

      conn = conn(:post, "/databases/crud/tables/items/write",
        Jason.encode!(%{key: "c", value: "3"})) |> call()
      assert conn.status == 200

      # Read
      conn = conn(:get, "/databases/crud/tables/items/read/b") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"key" => "b", "value" => "2"}

      # Read missing
      conn = conn(:get, "/databases/crud/tables/items/read/z") |> call()
      assert conn.status == 404

      # Scan
      conn = conn(:post, "/databases/crud/tables/items/scan",
        Jason.encode!(%{from: "a", to: "b"})) |> call()
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["results"] == [%{"key" => "a", "value" => "1"}, %{"key" => "b", "value" => "2"}]

      # Delete
      conn = conn(:delete, "/databases/crud/tables/items/delete/b") |> call()
      assert conn.status == 200
      conn = conn(:get, "/databases/crud/tables/items/read/b") |> call()
      assert conn.status == 404
    end
  end

  describe "cells" do
    test "write and read a cell" do
      conn(:post, "/databases", Jason.encode!(%{name: "celltest"})) |> call()

      conn = conn(:post, "/databases/celltest/cells/counter/write",
        Jason.encode!(%{value: "42"})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/databases/celltest/cells/counter/read") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"name" => "counter", "value" => "42"}
    end

    test "read missing cell returns 404" do
      conn(:post, "/databases", Jason.encode!(%{name: "celltest2"})) |> call()
      conn = conn(:get, "/databases/celltest2/cells/nope/read") |> call()
      assert conn.status == 404
    end
  end

  describe "transactions" do
    test "atomic batch of writes" do
      conn(:post, "/databases", Jason.encode!(%{name: "txtest"})) |> call()
      conn(:post, "/databases/txtest/tables/ledger") |> call()

      ops = [
        %{op: "write_table", table: "ledger", key: "alice", value: "100"},
        %{op: "write_table", table: "ledger", key: "bob", value: "200"},
        %{op: "write_cell", name: "total", value: "300"}
      ]

      conn = conn(:post, "/databases/txtest/tx", Jason.encode!(%{operations: ops})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/databases/txtest/tables/ledger/read/alice") |> call()
      assert Jason.decode!(conn.resp_body)["value"] == "100"

      conn = conn(:get, "/databases/txtest/cells/total/read") |> call()
      assert Jason.decode!(conn.resp_body)["value"] == "300"
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/api/router_test.exs`
Expected: FAIL — modules not found

- [ ] **Step 3: Implement the router**

Create `lib/uniops/api/router.ex`:

```elixir
defmodule Uniops.API.Router do
  @moduledoc """
  HTTP API router for Uniops storage operations.
  """

  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  get "/health" do
    Uniops.API.Json.send_json(conn, 200, %{status: "ok"})
  end

  # Database endpoints
  post "/databases" do
    Uniops.API.DatabaseController.create(conn)
  end

  get "/databases" do
    Uniops.API.DatabaseController.list(conn)
  end

  # OrderedTable endpoints
  post "/databases/:db/tables/:table" do
    Uniops.API.OrderedTableController.ensure(conn, db, table)
  end

  post "/databases/:db/tables/:table/write" do
    Uniops.API.OrderedTableController.write(conn, db, table)
  end

  get "/databases/:db/tables/:table/read/:key" do
    Uniops.API.OrderedTableController.read(conn, db, table, key)
  end

  delete "/databases/:db/tables/:table/delete/:key" do
    Uniops.API.OrderedTableController.delete(conn, db, table, key)
  end

  post "/databases/:db/tables/:table/scan" do
    Uniops.API.OrderedTableController.scan(conn, db, table)
  end

  # Cell endpoints
  post "/databases/:db/cells/:name/write" do
    Uniops.API.CellController.write(conn, db, name)
  end

  get "/databases/:db/cells/:name/read" do
    Uniops.API.CellController.read(conn, db, name)
  end

  # Transaction endpoint
  post "/databases/:db/tx" do
    Uniops.API.TransactionController.execute(conn, db)
  end

  match _ do
    Uniops.API.Json.send_json(conn, 404, %{error: "not_found"})
  end
end
```

- [ ] **Step 4: Implement the controllers**

Create `lib/uniops/api/database_controller.ex`:

```elixir
defmodule Uniops.API.DatabaseController do
  @moduledoc false

  alias Uniops.API.Json
  alias Uniops.Storage.Database

  def create(conn) do
    {:ok, %{"name" => name}} = Json.read_json(conn)

    case Database.create(name) do
      :ok -> Json.send_json(conn, 201, %{name: name})
      {:error, reason} -> Json.send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  def list(conn) do
    databases = Database.list()
    Json.send_json(conn, 200, %{databases: databases})
  end
end
```

Create `lib/uniops/api/ordered_table_controller.ex`:

```elixir
defmodule Uniops.API.OrderedTableController do
  @moduledoc false

  alias Uniops.API.Json
  alias Uniops.Storage.OrderedTable

  def ensure(conn, db, table) do
    case OrderedTable.ensure(db, table) do
      :ok -> Json.send_json(conn, 201, %{database: db, table: table})
      {:error, reason} -> Json.send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  def write(conn, db, table) do
    {:ok, %{"key" => key, "value" => value}} = Json.read_json(conn)
    :ok = OrderedTable.write(db, table, key, value)
    Json.send_json(conn, 200, %{key: key})
  end

  def read(conn, db, table, key) do
    case OrderedTable.read(db, table, key) do
      {:ok, value} -> Json.send_json(conn, 200, %{key: key, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found", key: key})
    end
  end

  def delete(conn, db, table, key) do
    :ok = OrderedTable.delete(db, table, key)
    Json.send_json(conn, 200, %{key: key})
  end

  def scan(conn, db, table) do
    {:ok, %{"from" => from, "to" => to}} = Json.read_json(conn)
    results = OrderedTable.scan(db, table, from, to)
    entries = Enum.map(results, fn {k, v} -> %{key: k, value: v} end)
    Json.send_json(conn, 200, %{results: entries})
  end
end
```

Create `lib/uniops/api/cell_controller.ex`:

```elixir
defmodule Uniops.API.CellController do
  @moduledoc false

  alias Uniops.API.Json
  alias Uniops.Storage.Cell

  def write(conn, db, name) do
    {:ok, %{"value" => value}} = Json.read_json(conn)
    :ok = Cell.write(db, name, value)
    Json.send_json(conn, 200, %{name: name})
  end

  def read(conn, db, name) do
    case Cell.read(db, name) do
      {:ok, value} -> Json.send_json(conn, 200, %{name: name, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found", name: name})
    end
  end
end
```

Create `lib/uniops/api/transaction_controller.ex`:

```elixir
defmodule Uniops.API.TransactionController do
  @moduledoc false

  alias Uniops.API.Json
  alias Uniops.Storage.Transaction

  def execute(conn, db) do
    {:ok, %{"operations" => raw_ops}} = Json.read_json(conn)

    ops = Enum.map(raw_ops, &parse_op/1)

    case Transaction.execute(db, ops) do
      :ok -> Json.send_json(conn, 200, %{status: "committed"})
      {:error, reason} -> Json.send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  defp parse_op(%{"op" => "write_table", "table" => t, "key" => k, "value" => v}),
    do: {:write_table, t, k, v}

  defp parse_op(%{"op" => "read_table", "table" => t, "key" => k}),
    do: {:read_table, t, k}

  defp parse_op(%{"op" => "delete_table", "table" => t, "key" => k}),
    do: {:delete_table, t, k}

  defp parse_op(%{"op" => "write_cell", "name" => n, "value" => v}),
    do: {:write_cell, n, v}

  defp parse_op(%{"op" => "read_cell", "name" => n}),
    do: {:read_cell, n}
end
```

- [ ] **Step 5: Add Bandit HTTP server to the supervision tree**

Update `lib/uniops/application.ex`:

```elixir
defmodule Uniops.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:uniops, :api_port, 4040)
    mnesia_dir = Application.get_env(:uniops, :mnesia_dir)

    if mnesia_dir do
      Uniops.Storage.Schema.init(mnesia_dir)
    end

    children = [
      {Bandit, plug: Uniops.API.Router, port: port}
    ]

    opts = [strategy: :one_for_one, name: Uniops.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 6: Run the router tests**

Run: `mix test test/uniops/api/router_test.exs`
Expected: 6 tests, 0 failures

Note: The router tests call the Plug directly (no HTTP server needed) via `Plug.Test`. The Bandit server is for actual runtime, not tests.

- [ ] **Step 7: Run the full test suite**

Run: `mix test`
Expected: All tests pass (existing Plan 1 tests + new storage + API tests)

Note: The Application module now starts Bandit and inits Mnesia. Existing tests that don't use storage should still pass because the Schema.init is conditional on config. If Plan 1 tests break because Bandit tries to bind a port, add to `config/config.exs`:

```elixir
# Only start the API server when configured
config :uniops, start_api: true
```

And guard the Bandit child in application.ex with `if Application.get_env(:uniops, :start_api, false)`. For tests, set this in `config/test.exs` or use `setup` to manage it.

If this becomes an issue, create `config/test.exs` with:
```elixir
import Config
config :uniops, start_api: false, mnesia_dir: nil
```

And add `import_config "#{config_env()}.exs"` at the end of `config/config.exs`.

- [ ] **Step 8: Commit**

```bash
jj desc -m "Add HTTP API router and controllers for storage operations"
jj new
```

---

### Task 9: End-to-End Unison Storage Test

**Files:**
- Create: `test/integration/unison_storage_test.exs`

The ultimate proof: a Unison program uses `@unison/http` to call our storage API, write data, read it back, and verify the result.

- [ ] **Step 1: Write the integration test**

Create `test/integration/unison_storage_test.exs`:

```elixir
defmodule Uniops.Integration.UnisonStorageTest do
  use ExUnit.Case, async: false

  @api_port 4041

  setup_all do
    # Start Mnesia
    dir = Path.join(System.tmp_dir!(), "uniops_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)

    # Start HTTP server on a test port
    {:ok, server} = Bandit.start_link(plug: Uniops.API.Router, port: @api_port)

    on_exit(fn ->
      GenServer.stop(server)
      :mnesia.stop()
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "Unison program writes and reads from storage via HTTP" do
    # This Unison program:
    # 1. Creates a database via POST
    # 2. Ensures a table via POST
    # 3. Writes a key-value pair via POST
    # 4. Reads it back via GET
    # 5. Prints the value
    source = """
    main : '{IO, Exception} ()
    main = do
      use Text ++
      base = "http://localhost:#{@api_port}"

      -- Create database
      createDbUri = URI.parse (base ++ "/databases")
      createDbBody = Bytes.fromList (Text.toUtf8 "{\\"name\\":\\"unisondb\\"}")
      createDbReq = Http.Request.post createDbUri createDbBody
      createDbReq' = Http.Request.header "Content-Type" "application/json" createDbReq
      _ = Http.request createDbReq'

      -- Ensure table
      ensureUri = URI.parse (base ++ "/databases/unisondb/tables/greetings")
      ensureReq = Http.Request.post ensureUri (Bytes.fromList [])
      _ = Http.request ensureReq

      -- Write
      writeUri = URI.parse (base ++ "/databases/unisondb/tables/greetings/write")
      writeBody = Bytes.fromList (Text.toUtf8 "{\\"key\\":\\"hello\\",\\"value\\":\\"world\\"}")
      writeReq = Http.Request.post writeUri writeBody
      writeReq' = Http.Request.header "Content-Type" "application/json" writeReq
      _ = Http.request writeReq'

      -- Read back
      readUri = URI.parse (base ++ "/databases/unisondb/tables/greetings/read/hello")
      readReq = Http.Request.get readUri
      response = Http.request readReq
      body = match response with
        Right resp -> Text.fromUtf8 (Bytes.toList (Http.Response.body resp))
        Left err -> bug (Failure.toText err)
      printLine ("RESULT: " ++ body)
    """

    assert {:ok, result} = Uniops.eval(source)
    assert result.stdout =~ "RESULT:"
    assert result.stdout =~ "world"
  end
end
```

**IMPORTANT:** The Unison HTTP API calls above are approximate. The exact function names and types in `@unison/http` may differ. If the test fails due to Unison typecheck errors:

1. Check the actual API by running `ucm` interactively and typing `find Http.Request` or `view Http.Request.post` to see the real signatures.
2. The workspace created by `Uniops.eval` needs `@unison/http` installed. You may need to modify `Uniops.Workspace.init_codebase` to also run `lib.install @unison/http` during project creation.
3. Simpler alternative if HTTP lib is tricky: use the `IO` ability with raw TCP sockets, or use `printLine` to output results and skip HTTP entirely for v1.

If the exact Unison HTTP API proves too complex to get right in this plan, **a valid fallback** is to test the HTTP API from Elixir only (which the router_test already does) and write a simpler Unison test that just verifies Unison code can make HTTP calls at all. The important thing is that the storage backend and HTTP API work.

- [ ] **Step 2: Install @unison/http in the workspace**

If the test fails because `Http` types are not found, modify `lib/uniops/workspace.ex` `init_codebase` to install the HTTP library:

Change the commands sent to UCM from:
```
"project.create uniops_base\nexit\n"
```
to:
```
"project.create uniops_base\nlib.install @unison/http\nexit\n"
```

This adds a one-time download of the HTTP library when creating workspaces. It will make workspace creation slower but ensures Unison programs can make HTTP calls.

- [ ] **Step 3: Run the integration test**

Run: `mix test test/integration/unison_storage_test.exs`
Expected: 1 test, 0 failures (Unison program successfully reads "world" from storage)

- [ ] **Step 4: Run the full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add end-to-end Unison storage integration test"
jj new
```

---

### Task 10: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full test suite with trace**

Run: `mix test --trace`
Expected: All tests pass with descriptive names

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation

- [ ] **Step 3: Manual smoke test — start the server and curl it**

Run in one terminal:
```bash
mix run --no-halt
```

Run in another:
```bash
# Health check
curl -s http://localhost:4040/health | jq .

# Create database
curl -s -X POST http://localhost:4040/databases -H 'Content-Type: application/json' -d '{"name":"demo"}' | jq .

# Ensure table
curl -s -X POST http://localhost:4040/databases/demo/tables/kv | jq .

# Write
curl -s -X POST http://localhost:4040/databases/demo/tables/kv/write -H 'Content-Type: application/json' -d '{"key":"greeting","value":"hello world"}' | jq .

# Read
curl -s http://localhost:4040/databases/demo/tables/kv/read/greeting | jq .

# Scan
curl -s -X POST http://localhost:4040/databases/demo/tables/kv/scan -H 'Content-Type: application/json' -d '{"from":"a","to":"z"}' | jq .
```

Expected: All return valid JSON with correct data.

- [ ] **Step 4: Commit final state**

```bash
jj desc -m "Complete Plan 2: Mnesia-backed storage with HTTP API"
```

---

## What This Plan Produces

After completing all tasks:

1. **Mnesia-backed storage** with OrderedTable (sorted KV + range scans), Cell (single values), and atomic Transactions
2. **A JSON HTTP API** on port 4040 exposing all storage operations
3. **An end-to-end test** proving Unison programs can call the storage API via HTTP
4. **22+ tests** covering storage internals, HTTP API, and Unison integration

This is the foundation for all data-persistence features. Plan 3 (Clustering) will extend Mnesia replication across BEAM nodes. Plan 4 (Remote) builds on Plan 3's clustering to ship computations. Plans 5-6 add Services, Config, Blobs, Scratch, and Log — all building on this storage layer.
