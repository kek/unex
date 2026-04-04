# Uniops Foundation: Elixir Shell + UCM Integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Elixir OTP application that manages UCM as a subprocess, compiles Unison source to bytecode, executes bytecode, and lays the foundation for all subsequent phases of the open-source Unison distributed runtime.

**Architecture:** A Mix/OTP application wraps UCM (Unison Codebase Manager v1.1.1) as a managed external process. Three execution modes are supported: `run.file` for quick single-file execution, `transcript` for batch codebase operations (add, compile), and `run.compiled` for executing pre-compiled `.uc` bytecode. A GenServer manages UCM lifecycle and serializes access. The Unison codebase directory is managed as a workspace abstraction.

**Tech Stack:** Elixir 1.17+ / Erlang/OTP 27+, ExUnit, UCM 1.1.1 (external binary on PATH), Port-based process management

---

## Scope Note

This is Plan 1 of 6 for the Uniops project (open-source Unison distributed runtime). This plan covers only the Elixir foundation and UCM integration. Subsequent plans:

- **Plan 2:** Storage ability handlers (Mnesia-backed, single node)
- **Plan 3:** BEAM clustering + hash cache + dependency sync
- **Plan 4:** Remote ability handler (computation shipping)
- **Plan 5:** Services registry (typed RPC)
- **Plan 6:** Supporting abilities (Config, Blobs, Scratch, Log)

## Prerequisites

- Elixir 1.17+ and Erlang/OTP 27+ installed (`elixir --version`, `erl -eval '...'`)
- UCM installed and on PATH (`ucm version` → should print `release/1.1.1` or compatible)
- If Elixir is not installed: `brew install elixir` (macOS) or follow https://elixir-lang.org/install.html

## File Structure

```
uniops/
├── mix.exs                              # Project definition, deps, config
├── config/
│   └── config.exs                       # Application config (UCM path, timeouts)
├── lib/
│   ├── uniops.ex                        # Public API facade
│   ├── uniops/
│   │   ├── application.ex               # OTP Application callback
│   │   ├── ucm.ex                       # UCM binary detection + version check
│   │   ├── workspace.ex                 # Unison codebase/project directory management
│   │   ├── compiler.ex                  # Compile .u → .uc via transcript
│   │   └── runner.ex                    # Execute Unison code (run.file, run.compiled)
├── test/
│   ├── test_helper.exs                  # ExUnit config
│   ├── uniops/
│   │   ├── ucm_test.exs                 # UCM detection tests
│   │   ├── workspace_test.exs           # Workspace management tests
│   │   ├── compiler_test.exs            # Compilation pipeline tests
│   │   └── runner_test.exs              # Execution pipeline tests
│   └── integration/
│       └── end_to_end_test.exs          # Full pipeline: write → compile → run
├── unison-mastery-guide.md              # (existing)
└── docs/                                # (existing)
```

---

### Task 1: Install Elixir/Erlang Runtime

**Files:** None (system setup)

- [ ] **Step 1: Install Erlang/OTP and Elixir**

Run:
```bash
# On Ubuntu/Debian (this system):
sudo apt-get update && sudo apt-get install -y erlang elixir
```

If apt packages are outdated, use asdf or mise instead:
```bash
# Alternative with mise (if available):
mise install erlang@27 elixir@1.17
```

- [ ] **Step 2: Verify installation**

Run: `elixir --version`
Expected: Output includes `Elixir 1.17.x` (or higher) and `Erlang/OTP 27` (or higher)

Run: `mix --version`
Expected: Output includes `Mix 1.17.x` (or higher)

---

### Task 2: Mix Project Scaffold

**Files:**
- Create: `mix.exs`
- Create: `config/config.exs`
- Create: `lib/uniops.ex`
- Create: `lib/uniops/application.ex`
- Create: `test/test_helper.exs`

- [ ] **Step 1: Initialize the Mix project**

Run from the repo root (`/Users/ke/lima-workspace/uniops`):
```bash
mix new . --app uniops --sup
```

This generates the skeleton. The `--sup` flag includes an Application supervisor. If Mix warns about existing files (like the guide), choose to keep them.

- [ ] **Step 2: Verify the generated project compiles**

Run: `mix compile`
Expected: `Compiling X file(s) (.ex)` with no errors

- [ ] **Step 3: Configure the application**

Replace `config/config.exs` with:

```elixir
import Config

config :uniops,
  ucm_path: System.get_env("UCM_PATH") || "ucm",
  ucm_timeout: String.to_integer(System.get_env("UCM_TIMEOUT") || "30000"),
  workspace_base: System.get_env("UNIOPS_WORKSPACE") || Path.join(System.tmp_dir!(), "uniops")
```

- [ ] **Step 4: Update mix.exs with project metadata**

Ensure `mix.exs` has:

```elixir
defmodule Uniops.MixProject do
  use Mix.Project

  def project do
    [
      app: :uniops,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Uniops.Application, []}
    ]
  end

  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    []
  end
end
```

- [ ] **Step 5: Set up the Application module**

Replace `lib/uniops/application.ex` with:

```elixir
defmodule Uniops.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = []

    opts = [strategy: :one_for_one, name: Uniops.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 6: Set up the public API module**

Replace `lib/uniops.ex` with:

```elixir
defmodule Uniops do
  @moduledoc """
  Open-source ops platform and distribution system for Unison.
  """
end
```

- [ ] **Step 7: Verify everything compiles and tests pass**

Run: `mix test`
Expected: `0 tests, 0 failures` (no tests yet, but compilation succeeds)

- [ ] **Step 8: Commit**

```bash
jj desc -m "Initialize Elixir Mix project with OTP application skeleton"
jj new
```

---

### Task 3: UCM Binary Detection and Version Check

**Files:**
- Create: `lib/uniops/ucm.ex`
- Create: `test/uniops/ucm_test.exs`

- [ ] **Step 1: Write the failing test for UCM detection**

Create `test/uniops/ucm_test.exs`:

```elixir
defmodule Uniops.UCMTest do
  use ExUnit.Case, async: true

  describe "find/0" do
    test "returns path to ucm binary" do
      assert {:ok, path} = Uniops.UCM.find()
      assert File.exists?(path)
    end

    test "returns error when binary not found" do
      assert {:error, :not_found} = Uniops.UCM.find(name: "ucm_nonexistent_binary")
    end
  end

  describe "version/0" do
    test "returns the UCM version string" do
      assert {:ok, version} = Uniops.UCM.version()
      assert version =~ ~r/\d+\.\d+\.\d+/
    end
  end

  describe "check!/0" do
    test "returns :ok when UCM is available" do
      assert :ok = Uniops.UCM.check!()
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/uniops/ucm_test.exs`
Expected: FAIL — `Uniops.UCM` module not found

- [ ] **Step 3: Implement UCM detection**

Create `lib/uniops/ucm.ex`:

```elixir
defmodule Uniops.UCM do
  @moduledoc """
  Detects and validates the UCM (Unison Codebase Manager) binary.
  """

  @doc """
  Finds the UCM binary on PATH. Returns `{:ok, absolute_path}` or `{:error, :not_found}`.
  """
  def find(opts \\ []) do
    name = Keyword.get(opts, :name, configured_path())

    case System.find_executable(name) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @doc """
  Returns the UCM version as `{:ok, version_string}` or `{:error, reason}`.
  """
  def version do
    with {:ok, path} <- find() do
      case System.cmd(path, ["--version"], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/(\d+\.\d+\.\d+)/, output) do
            [_, version] -> {:ok, version}
            nil -> {:error, {:parse_error, output}}
          end

        {output, code} ->
          {:error, {:exit, code, output}}
      end
    end
  end

  @doc """
  Verifies UCM is available and returns :ok. Raises on failure.
  """
  def check! do
    case find() do
      {:ok, _path} -> :ok
      {:error, :not_found} -> raise "UCM not found on PATH. Install from https://www.unison-lang.org/docs/quickstart/"
    end
  end

  defp configured_path do
    Application.get_env(:uniops, :ucm_path, "ucm")
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/ucm_test.exs`
Expected: 4 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add UCM binary detection and version check"
jj new
```

---

### Task 4: Workspace Management

**Files:**
- Create: `lib/uniops/workspace.ex`
- Create: `test/uniops/workspace_test.exs`

A workspace is an isolated directory containing a Unison codebase. Workspaces are used for compilation and execution. Each workspace has its own UCM codebase initialized via `ucm --codebase-create`.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/workspace_test.exs`:

```elixir
defmodule Uniops.WorkspaceTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_test_#{:rand.uniform(1_000_000)}")
    on_cleanup = fn -> File.rm_rf!(dir) end

    on_exit(on_cleanup)
    %{dir: dir}
  end

  describe "create/1" do
    test "creates a workspace directory with a Unison codebase", %{dir: dir} do
      assert {:ok, workspace} = Uniops.Workspace.create(dir)
      assert workspace.path == dir
      assert File.dir?(dir)
    end
  end

  describe "write_source/3" do
    test "writes a .u file into the workspace", %{dir: dir} do
      {:ok, workspace} = Uniops.Workspace.create(dir)
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "hello"
      """

      assert {:ok, file_path} = Uniops.Workspace.write_source(workspace, "scratch.u", source)
      assert File.exists?(file_path)
      assert File.read!(file_path) == source
    end
  end

  describe "destroy/1" do
    test "removes the workspace directory", %{dir: dir} do
      {:ok, workspace} = Uniops.Workspace.create(dir)
      assert :ok = Uniops.Workspace.destroy(workspace)
      refute File.dir?(dir)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/workspace_test.exs`
Expected: FAIL — `Uniops.Workspace` module not found

- [ ] **Step 3: Implement workspace management**

Create `lib/uniops/workspace.ex`:

```elixir
defmodule Uniops.Workspace do
  @moduledoc """
  Manages isolated Unison workspace directories containing codebases.
  """

  defstruct [:path]

  @type t :: %__MODULE__{path: String.t()}

  @doc """
  Creates a new workspace at the given path, initializing a Unison codebase.
  """
  def create(path) do
    File.mkdir_p!(path)
    %__MODULE__{path: path}
    |> tap(fn _ -> init_codebase(path) end)
    |> then(&{:ok, &1})
  end

  @doc """
  Writes Unison source code to a file in the workspace.
  """
  def write_source(%__MODULE__{path: ws_path}, filename, source) do
    file_path = Path.join(ws_path, filename)
    File.write!(file_path, source)
    {:ok, file_path}
  end

  @doc """
  Removes the workspace directory and all contents.
  """
  def destroy(%__MODULE__{path: path}) do
    File.rm_rf!(path)
    :ok
  end

  defp init_codebase(path) do
    {:ok, ucm} = Uniops.UCM.find()
    codebase_path = Path.join(path, ".unison")

    unless File.dir?(codebase_path) do
      System.cmd(ucm, ["--codebase-create", codebase_path, "--exit"],
        cd: path,
        stderr_to_stdout: true
      )
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/uniops/workspace_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add workspace management for isolated Unison codebases"
jj new
```

---

### Task 5: Unison Code Runner (run.file)

**Files:**
- Create: `lib/uniops/runner.ex`
- Create: `test/uniops/runner_test.exs`

UCM's `run.file` command executes a Unison function directly from a `.u` file without needing to add it to a codebase first. This is the simplest execution mode and ideal for quick one-off computations.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/runner_test.exs`:

```elixir
defmodule Uniops.RunnerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_runner_#{:rand.uniform(1_000_000)}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    on_exit(fn -> Uniops.Workspace.destroy(workspace) end)
    %{workspace: workspace}
  end

  describe "run_file/3" do
    test "executes a Unison function from a .u file and captures stdout", %{workspace: ws} do
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "hello from uniops"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "hello.u", source)

      assert {:ok, result} = Uniops.Runner.run_file(file_path, "myMain", codebase: ws.path)
      assert result.stdout =~ "hello from uniops"
      assert result.exit_code == 0
    end

    test "returns error for code that fails to typecheck", %{workspace: ws} do
      source = """
      broken : Nat
      broken = "not a nat"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "broken.u", source)

      assert {:error, result} = Uniops.Runner.run_file(file_path, "broken", codebase: ws.path)
      assert result.exit_code != 0
    end
  end

  describe "run_compiled/2" do
    test "executes a .uc bytecode file and captures stdout", %{workspace: ws} do
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "compiled hello"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "compiled_test.u", source)

      # First compile via transcript, then run compiled
      {:ok, uc_path} = Uniops.Compiler.compile(ws, file_path, "myMain", "compiled_test")

      assert {:ok, result} = Uniops.Runner.run_compiled(uc_path)
      assert result.stdout =~ "compiled hello"
      assert result.exit_code == 0
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/runner_test.exs`
Expected: FAIL — `Uniops.Runner` module not found

- [ ] **Step 3: Implement the runner**

Create `lib/uniops/runner.ex`:

```elixir
defmodule Uniops.Runner do
  @moduledoc """
  Executes Unison code via UCM's run.file and run.compiled commands.
  """

  defmodule Result do
    @moduledoc false
    defstruct [:stdout, :stderr, :exit_code]

    @type t :: %__MODULE__{
            stdout: String.t(),
            stderr: String.t(),
            exit_code: non_neg_integer()
          }
  end

  @doc """
  Executes a Unison function from a .u source file using `ucm run.file`.

  Options:
    - `:codebase` - path to the workspace directory (required for codebase resolution)
    - `:timeout` - max execution time in ms (default: 30_000)
    - `:args` - list of string arguments to pass to the program
  """
  def run_file(file_path, symbol, opts \\ []) do
    {:ok, ucm} = Uniops.UCM.find()
    timeout = Keyword.get(opts, :timeout, configured_timeout())
    args = Keyword.get(opts, :args, [])
    codebase = Keyword.get(opts, :codebase)

    ucm_args =
      codebase_args(codebase) ++
        ["run.file", file_path, symbol] ++
        args

    run_ucm(ucm, ucm_args, timeout, opts)
  end

  @doc """
  Executes a compiled .uc bytecode file using `ucm run.compiled`.

  Options:
    - `:timeout` - max execution time in ms (default: 30_000)
    - `:args` - list of string arguments to pass to the program
  """
  def run_compiled(uc_path, opts \\ []) do
    {:ok, ucm} = Uniops.UCM.find()
    timeout = Keyword.get(opts, :timeout, configured_timeout())
    args = Keyword.get(opts, :args, [])

    ucm_args = ["run.compiled", uc_path] ++ args

    run_ucm(ucm, ucm_args, timeout, opts)
  end

  defp run_ucm(ucm, args, timeout, _opts) do
    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    collect_output(port, "", timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, %Result{stdout: acc, stderr: "", exit_code: 0}}

      {^port, {:exit_status, code}} ->
        {:error, %Result{stdout: acc, stderr: "", exit_code: code}}
    after
      timeout ->
        Port.close(port)
        {:error, %Result{stdout: acc, stderr: "timeout after #{timeout}ms", exit_code: -1}}
    end
  end

  defp codebase_args(nil), do: []

  defp codebase_args(workspace_path) do
    codebase = Path.join(workspace_path, ".unison")

    if File.dir?(codebase) do
      ["--codebase", codebase]
    else
      ["--codebase-create", codebase]
    end
  end

  defp configured_timeout do
    Application.get_env(:uniops, :ucm_timeout, 30_000)
  end
end
```

- [ ] **Step 4: Run the run_file tests (skip run_compiled for now — depends on Compiler)**

Run: `mix test test/uniops/runner_test.exs --exclude "run_compiled"`

If ExUnit doesn't support `--exclude` by test name, run just the first describe block:
Run: `mix test test/uniops/runner_test.exs:12`
Expected: 2 tests pass (the `run_file` tests). The `run_compiled` test will fail because `Uniops.Compiler` doesn't exist yet — that's expected and will be fixed in Task 6.

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add Unison code runner with run.file and run.compiled support"
jj new
```

---

### Task 6: Bytecode Compiler (transcript-based)

**Files:**
- Create: `lib/uniops/compiler.ex`
- Create: `test/uniops/compiler_test.exs`

Compilation uses UCM's transcript mode. We generate a markdown transcript file that loads code into a temporary project and compiles it to a `.uc` file, then execute the transcript via `ucm transcript`.

- [ ] **Step 1: Write the failing tests**

Create `test/uniops/compiler_test.exs`:

```elixir
defmodule Uniops.CompilerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_compiler_#{:rand.uniform(1_000_000)}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    on_exit(fn -> Uniops.Workspace.destroy(workspace) end)
    %{workspace: workspace}
  end

  describe "compile/4" do
    test "compiles a Unison function to .uc bytecode", %{workspace: ws} do
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "compiled"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "compile_me.u", source)

      assert {:ok, uc_path} = Uniops.Compiler.compile(ws, file_path, "myMain", "output")
      assert File.exists?(uc_path)
      assert String.ends_with?(uc_path, ".uc")
    end

    test "returns error for code that fails to typecheck", %{workspace: ws} do
      source = """
      broken : Nat
      broken = "oops"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "broken.u", source)

      assert {:error, _reason} = Uniops.Compiler.compile(ws, file_path, "broken", "broken_out")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/uniops/compiler_test.exs`
Expected: FAIL — `Uniops.Compiler` module not found

- [ ] **Step 3: Implement the compiler**

Create `lib/uniops/compiler.ex`:

```elixir
defmodule Uniops.Compiler do
  @moduledoc """
  Compiles Unison source code to .uc bytecode using UCM transcript mode.
  """

  @doc """
  Compiles a Unison function from a source file into a .uc bytecode file.

  - `workspace` - the Uniops.Workspace struct
  - `source_path` - path to the .u source file
  - `symbol` - the function name to compile (e.g., "myMain")
  - `output_name` - name for the output file (without .uc extension)

  Returns `{:ok, uc_path}` or `{:error, reason}`.
  """
  def compile(%Uniops.Workspace{path: ws_path} = _workspace, source_path, symbol, output_name) do
    {:ok, ucm} = Uniops.UCM.find()
    source = File.read!(source_path)

    # Build a transcript that loads the code, adds it, and compiles it
    transcript = build_transcript(source, symbol, output_name)

    transcript_path = Path.join(ws_path, "_compile_transcript.md")
    File.write!(transcript_path, transcript)

    codebase_path = Path.join(ws_path, ".unison")
    timeout = Application.get_env(:uniops, :ucm_timeout, 60_000)

    case System.cmd(ucm, ["transcript", "--save-codebase", "--codebase", codebase_path, transcript_path],
           cd: ws_path,
           stderr_to_stdout: true,
           timeout: timeout
         ) do
      {output, 0} ->
        # UCM transcript --save-codebase writes the codebase to a new directory
        # The .uc file is created relative to the codebase directory
        uc_path = find_uc_file(ws_path, output_name)

        if uc_path do
          {:ok, uc_path}
        else
          {:error, {:uc_not_found, output}}
        end

      {output, code} ->
        {:error, {:compilation_failed, code, output}}
    end
  after
    # Clean up transcript file
    transcript_path = Path.join(_workspace.path, "_compile_transcript.md")
    File.rm(transcript_path)
  end

  defp build_transcript(source, symbol, output_name) do
    """
    ```ucm:hide
    scratch/main> builtins.mergeio
    ```

    ```unison
    #{String.trim(source)}
    ```

    ```ucm
    scratch/main> add
    scratch/main> compile #{symbol} #{output_name}
    ```
    """
  end

  defp find_uc_file(ws_path, output_name) do
    # Search for the .uc file — UCM may place it in different locations
    expected_name = "#{output_name}.uc"

    Path.wildcard(Path.join([ws_path, "**", expected_name]))
    |> List.first()
  end
end
```

- [ ] **Step 4: Run the compiler tests**

Run: `mix test test/uniops/compiler_test.exs`
Expected: 2 tests, 0 failures

Note: If the transcript format doesn't work as expected with UCM 1.1.1, adjust the `build_transcript/3` function. The `builtins.mergeio` command ensures IO abilities are available. The transcript format may need tweaking based on UCM's exact behavior — check `ucm transcript --help` and the transcript output for clues.

- [ ] **Step 5: Commit**

```bash
jj desc -m "Add bytecode compiler using UCM transcript mode"
jj new
```

---

### Task 7: Complete the run_compiled Test

**Files:**
- Modify: `test/uniops/runner_test.exs`

Now that the Compiler exists, the `run_compiled` test from Task 5 should pass.

- [ ] **Step 1: Run the full runner test suite**

Run: `mix test test/uniops/runner_test.exs`
Expected: 3 tests, 0 failures (including the `run_compiled` test that compiles first, then runs)

- [ ] **Step 2: If the run_compiled test fails, debug**

Check:
1. Does `Uniops.Compiler.compile/4` produce a valid `.uc` file? Run `mix test test/uniops/compiler_test.exs -v` to verify.
2. Is the `.uc` path correct? Add `IO.inspect(uc_path, label: "uc_path")` temporarily.
3. Does `ucm run.compiled <path>` work manually? Run it in a terminal.

Fix any issues, re-run.

- [ ] **Step 3: Commit**

```bash
jj desc -m "Verify end-to-end compile and run.compiled pipeline"
jj new
```

---

### Task 8: Public API Facade

**Files:**
- Modify: `lib/uniops.ex`
- Create: `test/integration/end_to_end_test.exs`

Expose a clean top-level API that composes workspace, compiler, and runner.

- [ ] **Step 1: Write the failing integration test**

Create `test/integration/end_to_end_test.exs`:

```elixir
defmodule Uniops.Integration.EndToEndTest do
  use ExUnit.Case, async: false

  describe "eval/2" do
    test "evaluates Unison source code and returns stdout" do
      source = """
      main : '{IO, Exception} ()
      main = do printLine "42"
      """

      assert {:ok, result} = Uniops.eval(source)
      assert result.stdout =~ "42"
    end

    test "evaluates with custom entry point" do
      source = """
      greet : '{IO, Exception} ()
      greet = do printLine "hi there"
      """

      assert {:ok, result} = Uniops.eval(source, entry: "greet")
      assert result.stdout =~ "hi there"
    end
  end

  describe "compile_and_run/2" do
    test "compiles to bytecode and executes it" do
      source = """
      main : '{IO, Exception} ()
      main = do printLine "bytecode works"
      """

      assert {:ok, result} = Uniops.compile_and_run(source)
      assert result.stdout =~ "bytecode works"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/integration/end_to_end_test.exs`
Expected: FAIL — `Uniops.eval/2` not defined

- [ ] **Step 3: Implement the facade**

Replace `lib/uniops.ex` with:

```elixir
defmodule Uniops do
  @moduledoc """
  Open-source ops platform and distribution system for Unison.

  Provides high-level functions to evaluate, compile, and run Unison programs.
  """

  @doc """
  Evaluates Unison source code using `ucm run.file` (no compilation step).

  Options:
    - `:entry` - function name to execute (default: "main")
    - `:timeout` - execution timeout in ms (default: 30_000)
    - `:args` - arguments to pass to the program
  """
  def eval(source, opts \\ []) do
    entry = Keyword.get(opts, :entry, "main")

    with_workspace(fn workspace ->
      {:ok, file_path} = Uniops.Workspace.write_source(workspace, "eval.u", source)
      Uniops.Runner.run_file(file_path, entry, Keyword.merge(opts, codebase: workspace.path))
    end)
  end

  @doc """
  Compiles Unison source to .uc bytecode, then executes it.

  Options:
    - `:entry` - function name to compile and execute (default: "main")
    - `:timeout` - execution timeout in ms (default: 30_000)
    - `:args` - arguments to pass to the program
  """
  def compile_and_run(source, opts \\ []) do
    entry = Keyword.get(opts, :entry, "main")

    with_workspace(fn workspace ->
      {:ok, file_path} = Uniops.Workspace.write_source(workspace, "program.u", source)

      case Uniops.Compiler.compile(workspace, file_path, entry, "program") do
        {:ok, uc_path} -> Uniops.Runner.run_compiled(uc_path, opts)
        {:error, _} = err -> err
      end
    end)
  end

  defp with_workspace(fun) do
    dir = Path.join(workspace_base(), "ws_#{:rand.uniform(1_000_000_000)}")
    {:ok, workspace} = Uniops.Workspace.create(dir)

    try do
      fun.(workspace)
    after
      Uniops.Workspace.destroy(workspace)
    end
  end

  defp workspace_base do
    Application.get_env(:uniops, :workspace_base, Path.join(System.tmp_dir!(), "uniops"))
  end
end
```

- [ ] **Step 4: Run the integration tests**

Run: `mix test test/integration/end_to_end_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: All tests pass (approximately 11 tests, 0 failures)

- [ ] **Step 6: Commit**

```bash
jj desc -m "Add public API facade with eval and compile_and_run"
jj new
```

---

### Task 9: Final Verification and Cleanup

**Files:**
- Review all files for consistency

- [ ] **Step 1: Run the full test suite with verbose output**

Run: `mix test --trace`
Expected: All tests pass with descriptive test names

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation with no warnings

- [ ] **Step 3: Verify the application starts correctly**

Run: `mix run -e "IO.inspect Uniops.UCM.version()"`
Expected: `{:ok, "1.1.1"}` (or current UCM version)

- [ ] **Step 4: Run a manual smoke test**

Run:
```bash
mix run -e '
source = """
main : \'{IO, Exception} ()
main = do printLine "Uniops is alive!"
"""
{:ok, result} = Uniops.eval(source)
IO.puts(result.stdout)
'
```
Expected: `Uniops is alive!` printed to stdout

- [ ] **Step 5: Commit the final state**

```bash
jj desc -m "Complete Plan 1: Elixir shell with UCM integration"
```

---

## What This Plan Produces

After completing all tasks, you have:

1. **An Elixir OTP application** (`uniops`) that starts cleanly
2. **UCM detection** — finds UCM on PATH, checks version
3. **Workspace management** — creates/destroys isolated Unison codebase directories
4. **Two execution modes:**
   - `Uniops.eval/2` — quick evaluation via `ucm run.file` (no compilation)
   - `Uniops.compile_and_run/2` — compile to `.uc` bytecode then execute
5. **A test suite** covering all modules with both unit and integration tests

This foundation supports all subsequent plans. Plan 2 (Storage handlers) will add Unison ability handler code that runs through this same pipeline. Plan 3 (Clustering) will extend the Application supervision tree with BEAM distribution.
