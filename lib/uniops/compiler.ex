defmodule Uniops.Compiler do
  @moduledoc """
  Compiles Unison source code to .uc bytecode via interactive UCM.

  Uses the same port-based approach as workspace initialization:
  loads source with `load`, adds definitions with `add`, then
  compiles to a .uc file with `compile`.
  """

  @default_timeout 60_000

  @doc """
  Compiles a Unison function from a source file to .uc bytecode.

  Arguments:
    - `workspace` - a `%Uniops.Workspace{}` struct with an initialized codebase
    - `source_path` - absolute path to the .u source file
    - `symbol` - the function name to compile (must have type `'{IO, Exception} ()`)
    - `output_name` - base name for the output .uc file (without extension)

  Returns `{:ok, uc_path}` on success or `{:error, reason}` on failure.
  """
  def compile(%Uniops.Workspace{path: ws_path} = _workspace, source_path, symbol, output_name) do
    {:ok, ucm} = Uniops.UCM.find()
    codebase_path = Path.join(ws_path, ".unison")
    uc_output_path = Path.join(ws_path, output_name)

    commands = "load #{source_path}\nadd\ncompile #{symbol} #{uc_output_path}\nexit\n"

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase", codebase_path],
        cd: ws_path
      ])

    send(port, {self(), {:command, commands}})
    output = collect_output(port, "", @default_timeout)

    uc_file = uc_output_path <> ".uc"

    cond do
      Uniops.UCM.Output.error?(output) ->
        {:error, output}

      File.exists?(uc_file) ->
        {:ok, uc_file}

      true ->
        {:error, "Compilation produced no output file. UCM output: #{output}"}
    end
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, _code}} ->
        acc
    after
      timeout ->
        Port.close(port)
        acc
    end
  end

end
