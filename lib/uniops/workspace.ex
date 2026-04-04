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
      port =
        Port.open({:spawn_executable, ucm}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["--codebase-create", codebase_path]
        ])

      send(port, {self(), {:command, "project.create uniops_base\nexit\n"}})
      collect_init_output(port, 60_000)
    end
  end

  defp collect_init_output(port, timeout) do
    receive do
      {^port, {:data, _data}} ->
        collect_init_output(port, timeout)

      {^port, {:exit_status, _code}} ->
        :ok
    after
      timeout ->
        Port.close(port)
        :ok
    end
  end
end
