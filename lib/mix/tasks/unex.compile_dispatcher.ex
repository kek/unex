defmodule Mix.Tasks.Unex.CompileDispatcher do
  @moduledoc """
  Compiles the Unex dispatcher Unison program into a `.uc` bundle that
  `Unex.Dispatcher` runs via `ucm run.compiled`.

  Steps:

    1. Ensure the runtime codebase exists and has `@unison/base`, `@unison/http`,
       and `@kek/unex` installed (this is the same codebase `Unex.Runtime` uses).
    2. Load `unison/Unex/Dispatcher.u` into the codebase.
    3. `compile Unex.Dispatcher.main <out>` — writes `<out>.uc`.

  Output path defaults to `$UNEX_DATA/dispatcher.uc` (where UNEX_DATA defaults
  to `./data`). Override with `--out <path>`.
  """

  use Mix.Task

  @shortdoc "Compile the Unex dispatcher to a .uc bundle"

  @dispatcher_src "unison/Unex/Dispatcher.u"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])

    data_dir = System.get_env("UNEX_DATA", "data")
    codebase = Path.join(data_dir, "runtime_codebase") |> Path.expand()
    out_path = Keyword.get(opts, :out, Path.join(data_dir, "dispatcher") |> Path.expand())

    unless File.exists?(@dispatcher_src) do
      Mix.raise("Dispatcher source not found at #{@dispatcher_src}")
    end

    {:ok, ucm} = Unex.UCM.find()

    unless File.dir?(codebase) do
      Mix.shell().info("Initializing runtime codebase at #{codebase}")

      init_cmds =
        "project.create runtime\n" <>
          "lib.install @unison/base\n" <>
          "lib.install @unison/http\n" <>
          "lib.install @kek/unex\n" <>
          "exit\n"

      run_ucm(ucm, ["--codebase-create", codebase], init_cmds)
    end

    Mix.shell().info("Compiling #{@dispatcher_src} -> #{out_path}.uc")

    commands =
      "load #{@dispatcher_src}\n" <>
        "update\n" <>
        "compile Unex.Dispatcher.main #{out_path}\n" <>
        "exit\n"

    run_ucm(ucm, ["--codebase", codebase], commands)

    uc = "#{out_path}.uc"

    if File.exists?(uc) do
      Mix.shell().info("Wrote #{uc} (#{File.stat!(uc).size} bytes)")
    else
      Mix.raise("ucm compile did not produce #{uc} — check output above")
    end
  end

  defp run_ucm(ucm, args, stdin_commands) do
    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    send(port, {self(), {:command, stdin_commands}})
    collect(port, "")
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        collect(port, acc <> data)

      {^port, {:exit_status, _}} ->
        acc
    after
      180_000 ->
        Port.close(port)
        acc
    end
  end
end
