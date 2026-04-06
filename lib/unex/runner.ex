defmodule Unex.Runner do
  @moduledoc """
  Executes Unison code via UCM's run.file and run.compiled commands.
  """

  defmodule Result do
    @moduledoc false
    defstruct [:stdout, :stderr, :exit_code]

    @type t :: %__MODULE__{
            stdout: String.t(),
            stderr: String.t(),
            exit_code: integer()
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
    {:ok, ucm} = Unex.UCM.find()
    timeout = Keyword.get(opts, :timeout, configured_timeout())
    args = Keyword.get(opts, :args, [])
    codebase = Keyword.get(opts, :codebase)

    ucm_args =
      codebase_args(codebase) ++
        ["run.file", file_path, symbol] ++
        args

    run_ucm(ucm, ucm_args, timeout)
  end

  @doc """
  Executes a compiled .uc bytecode file using `ucm run.compiled`.

  Options:
    - `:timeout` - max execution time in ms (default: 30_000)
    - `:args` - list of string arguments to pass to the program
  """
  def run_compiled(uc_path, opts \\ []) do
    {:ok, ucm} = Unex.UCM.find()
    timeout = Keyword.get(opts, :timeout, configured_timeout())
    args = Keyword.get(opts, :args, [])

    ucm_args = ["run.compiled", uc_path] ++ args

    run_ucm(ucm, ucm_args, timeout)
  end

  defp run_ucm(ucm, args, timeout) do
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
        if Unex.UCM.Output.error?(acc) do
          {:error, %Result{stdout: acc, stderr: "", exit_code: 1}}
        else
          {:ok, %Result{stdout: acc, stderr: "", exit_code: 0}}
        end

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
    Application.get_env(:unex, :ucm_timeout, 30_000)
  end
end
