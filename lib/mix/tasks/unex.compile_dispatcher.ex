defmodule Mix.Tasks.Unex.CompileDispatcher do
  @moduledoc """
  Compiles the Unex dispatcher Unison program into a `.uc` bundle that
  `Unex.Dispatcher` runs via `ucm run.compiled`.

  Steps:

    1. Ensure the runtime codebase exists and has `@unison/base`, `@unison/http`,
       and `@kek/unex` installed (this is the same codebase `Unex.Runtime` uses).
    2. Load `unison/Unex/Dispatcher.u` into the codebase.
    3. `compile Unex.Dispatcher.main <out>` — writes `<out>.uc`.

  Output path resolution (first match wins):

    * `--out <path>` flag (must end in `.uc`)
    * `UNEX_DISPATCHER` env var (must end in `.uc`)
    * `$UNEX_DATA/dispatcher.uc` (where UNEX_DATA defaults to `./data`)

  The runtime reads `UNEX_DISPATCHER` too, so setting it once lets the same
  shared binary be compiled and consumed by every node.
  """

  use Mix.Task

  @shortdoc "Compile the Unex dispatcher to a .uc bundle"

  @dispatcher_src "unison/Unex/Dispatcher.u"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])

    data_dir = System.get_env("UNEX_DATA", "data")
    codebase = Path.join(data_dir, "runtime_codebase") |> Path.expand()
    out_path = resolve_out_path(opts, data_dir)

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

  # ucm's `compile` takes the path WITHOUT the `.uc` extension and appends it
  # itself. We accept fully-qualified `.uc` paths externally so users can copy
  # the same value into `UNEX_DISPATCHER` for the runtime, then strip `.uc`
  # before handing it to ucm.
  defp resolve_out_path(opts, data_dir) do
    raw =
      Keyword.get(opts, :out) ||
        System.get_env("UNEX_DISPATCHER") ||
        Path.join(data_dir, "dispatcher.uc")

    raw
    |> Path.expand()
    |> strip_uc_suffix()
  end

  defp strip_uc_suffix(path) do
    case Path.extname(path) do
      ".uc" -> Path.rootname(path)
      "" -> path
      other -> Mix.raise("dispatcher output path must end in .uc, got #{other}: #{path}")
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
