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
    dir = Path.join(workspace_base(), "ws_#{System.unique_integer([:positive])}")

    case Uniops.Workspace.create(dir) do
      {:ok, workspace} ->
        try do
          fun.(workspace)
        after
          Uniops.Workspace.destroy(workspace)
        end

      {:error, _} = err ->
        err
    end
  end

  defp workspace_base do
    Application.get_env(:uniops, :workspace_base, Path.join(System.tmp_dir!(), "uniops"))
  end
end
