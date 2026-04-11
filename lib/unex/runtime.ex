defmodule Unex.Runtime do
  @moduledoc """
  Manages a persistent UCM codebase for server-side compilation.

  On deploy, pulls a project from Unison Share into the local codebase,
  compiles the entry point to .uc bytecode, and returns the bytes.
  """

  use GenServer

  require Logger

  @compile_timeout 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pulls a project from Unison Share and compiles an entry point.

  Returns `{:ok, uc_bytes}` or `{:error, reason}`.
  """
  def compile(server \\ __MODULE__, project, hash) do
    GenServer.call(server, {:compile, project, hash}, @compile_timeout)
  end

  @impl true
  def init(_opts) do
    codebase_path = Path.join(data_dir(), "runtime")
    unison_path = Path.join(codebase_path, ".unison")

    unless File.dir?(unison_path) do
      Logger.info("Runtime: initializing codebase at #{codebase_path}")
      File.mkdir_p!(codebase_path)
      init_codebase(codebase_path)
    end

    Logger.info("Runtime: codebase ready at #{codebase_path}")
    {:ok, %{codebase_path: codebase_path}}
  end

  @impl true
  def handle_call({:compile, project, hash}, _from, state) do
    result = do_compile(state.codebase_path, project, hash)
    {:reply, result, state}
  end

  defp do_compile(codebase_path, project, hash) do
    {:ok, ucm} = Unex.UCM.find()
    unison_path = Path.join(codebase_path, ".unison")
    output_path = Path.join(System.tmp_dir!(), "unex_compile_#{hash}")

    commands = "pull #{project} .deployments.h#{hash}\ncompile .deployments.h#{hash} #{output_path}\nexit\n"

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase", unison_path],
        cd: codebase_path
      ])

    send(port, {self(), {:command, commands}})
    output = collect_output(port, "", @compile_timeout)

    uc_file = output_path <> ".uc"

    cond do
      Unex.UCM.Output.error?(output) ->
        {:error, output}

      File.exists?(uc_file) ->
        bytes = File.read!(uc_file)
        File.rm(uc_file)
        {:ok, bytes}

      true ->
        {:error, "Compilation produced no output. UCM output: #{output}"}
    end
  end

  defp init_codebase(codebase_path) do
    {:ok, ucm} = Unex.UCM.find()
    unison_path = Path.join(codebase_path, ".unison")

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase-create", unison_path],
        cd: codebase_path
      ])

    commands = "project.create runtime\nlib.install @unison/base\nlib.install @unison/http\nlib.install @kek/unex\nexit\n"
    send(port, {self(), {:command, commands}})
    collect_output(port, "", @compile_timeout)
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

  defp data_dir do
    Application.get_env(:unex, :data_dir, "data")
  end
end
