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

  @doc """
  Pulls a project from Unison Share and extracts an entry point as a
  serialized `Value` plus its transitively reachable `Code` bytes.

  The `entry_point` must name a `'{IO, Exception} Text` thunk. Returns
  `{:ok, %{root_value: bytes, codes: %{term_text => code_bytes}}}` where
  `term_text` is the `Link.Term.toText` representation of each dep
  (including the leading `#`). Returns `{:error, reason}` on failure.

  This is the deploy-time companion to `Unex.Dispatcher`, which evaluates
  the `root_value` at call time and fetches `code` bytes on demand.
  """
  def extract(server \\ __MODULE__, project, entry_point) do
    GenServer.call(server, {:extract, project, entry_point}, @compile_timeout)
  end

  @impl true
  def init(_opts) do
    codebase_path = Path.expand(Path.join(data_dir(), "runtime_codebase"))

    unless File.dir?(codebase_path) do
      Logger.info("Runtime: initializing codebase at #{codebase_path}")
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

  def handle_call({:extract, project, entry_point}, _from, state) do
    result = do_extract(state.codebase_path, project, entry_point)
    {:reply, result, state}
  end

  defp do_compile(codebase_path, project, entry_point) do
    {:ok, ucm} = Unex.UCM.find()
    output_path = Path.join(System.tmp_dir!(), "unex_compile_#{:erlang.phash2(entry_point)}")

    commands = "pull #{project}\ncompile #{entry_point} #{output_path}\nexit\n"

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase", codebase_path]
      ])

    send(port, {self(), {:command, commands}})
    output = collect_output(port, "", @compile_timeout)

    uc_file = output_path <> ".uc"

    cond do
      File.exists?(uc_file) ->
        bytes = File.read!(uc_file)
        File.rm(uc_file)
        {:ok, bytes}

      true ->
        {:error, "Compilation failed. UCM output: #{output}"}
    end
  end

  defp do_extract(codebase_path, project, entry_point) do
    cond do
      not Regex.match?(~r/^[a-zA-Z0-9_.]+$/, entry_point) ->
        {:error, "invalid entry_point: #{inspect(entry_point)}"}

      true ->
        {:ok, ucm} = Unex.UCM.find()
        unique = "#{:erlang.phash2(entry_point)}_#{:os.system_time(:millisecond)}"
        out_dir = Path.join(System.tmp_dir!(), "unex_extract_#{unique}")
        File.rm_rf!(out_dir)
        File.mkdir_p!(out_dir)

        extractor_path = Path.join(out_dir, "_extractor.u")
        File.write!(extractor_path, extractor_source(entry_point, out_dir))

        commands =
          "pull #{project}\n" <>
            "load #{extractor_path}\n" <>
            "run Unex.Extract.main\n" <>
            "exit\n"

        port =
          Port.open({:spawn_executable, ucm}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["--codebase", codebase_path]
          ])

        send(port, {self(), {:command, commands}})
        output = collect_output(port, "", @compile_timeout)

        root_path = Path.join(out_dir, "root.value")

        try do
          if File.exists?(root_path) do
            root_value = File.read!(root_path)

            codes =
              out_dir
              |> File.ls!()
              |> Enum.filter(&String.ends_with?(&1, ".code"))
              |> Enum.into(%{}, fn fname ->
                term_text = String.replace_suffix(fname, ".code", "")
                {term_text, File.read!(Path.join(out_dir, fname))}
              end)

            {:ok, %{root_value: root_value, codes: codes}}
          else
            {:error, "extraction failed. UCM output:\n#{output}"}
          end
        after
          File.rm_rf!(out_dir)
        end
    end
  end

  defp extractor_source(entry_point, out_dir) do
    """
    Unex.Extract.walk : [Link.Term] -> [Link.Term] ->{IO, Exception} [Link.Term]
    Unex.Extract.walk seen frontier = match frontier with
      []      -> seen
      t +: ts ->
        if List.contains t seen then Unex.Extract.walk seen ts
        else match Code.lookup t with
          None      -> Unex.Extract.walk (t +: seen) ts
          Some code ->
            path = FilePath ("#{out_dir}/" Text.++ Link.Term.toText t Text.++ ".code")
            FilePath.writeFile path (Code.serialize_v3 code)
            Unex.Extract.walk (t +: seen) (ts List.++ Code.dependencies code)

    Unex.Extract.main : '{IO, Exception} ()
    Unex.Extract.main = do
      v = Value.value #{entry_point}
      FilePath.writeFile (FilePath "#{out_dir}/root.value") (Value.serialize_v4 v)
      _ = Unex.Extract.walk [] (Value.dependencies v)
      ()
    """
  end

  defp init_codebase(codebase_path) do
    {:ok, ucm} = Unex.UCM.find()

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase-create", codebase_path]
      ])

    commands =
      "project.create runtime\nlib.install @unison/base\nlib.install @unison/http\nlib.install @kek/unex\nexit\n"

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
