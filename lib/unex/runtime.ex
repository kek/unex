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
            "view #{entry_point}\n" <>
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

            manifest_path = Path.join(out_dir, "manifest.txt")
            manifest = if File.exists?(manifest_path), do: File.read!(manifest_path), else: ""

            Logger.info(
              "Runtime.extract: walked #{length(String.split(manifest, "\n", trim: true))} terms, wrote #{map_size(codes)} codes"
            )

            source = parse_view_output(output, entry_point)

            {:ok, %{root_value: root_value, codes: codes, source: source}}
          else
            {:error, "extraction failed. UCM output:\n#{output}"}
          end
        after
          File.rm_rf!(out_dir)
        end
    end
  end

  @doc false
  # Parses UCM stdout to extract the pretty-printed source body produced
  # by `view <entry_point>`. UCM echoes each command with a prompt prefix
  # (typically `.> ` or similar project-qualified forms like `project/branch>`).
  # We locate the last occurrence of a prompt line ending with
  # `view <entry_point>`, then take the text up to the next prompt line
  # (which will be from the subsequent `exit` command).
  # Returns nil if the view block can't be isolated.
  def parse_view_output(output, entry_point) when is_binary(output) do
    view_marker = "view " <> entry_point

    case :binary.matches(output, view_marker) do
      [] ->
        nil

      matches ->
        {start, len} = List.last(matches)
        rest = binary_part(output, start + len, byte_size(output) - start - len)
        # Skip to end of the view command line.
        after_cmd =
          case :binary.split(rest, "\n") do
            [_, tail] -> tail
            [_] -> ""
          end

        body = take_until_next_prompt(after_cmd)
        trimmed = String.trim(body)
        if trimmed == "", do: nil, else: trimmed
    end
  end

  # Collects lines until we hit a line that looks like a UCM prompt line
  # (matches something like `name>` or `.>` optionally followed by a command).
  # UCM's prompts end with `> ` and start at column 0.
  defp take_until_next_prompt(text) do
    text
    |> String.split("\n")
    |> Enum.reduce_while([], fn line, acc ->
      if prompt_line?(line) do
        {:halt, acc}
      else
        {:cont, [line | acc]}
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp prompt_line?(line) do
    # Prompt lines typically look like `scratch/main>`, `.>`, `project/branch>`.
    # The heuristic: a non-indented line containing `> ` or ending with `>`
    # where the part before `>` has no spaces.
    Regex.match?(~r/^[^\s>]*>\s?/, line)
  end

  defp extractor_source(entry_point, out_dir) do
    """
    -- Terms whose Link.Term.toText begins with `##` are Unison runtime
    -- builtins (e.g. `##Nat.+`, `##IO.getEnv.impl.v1`). Their Code cannot be
    -- serialized via Code.serialize_v3 ("putFunc: could not serialize foreign
    -- operation: ..."), and there's no need to — the dispatcher runtime
    -- already has them baked in. Skip them.
    Unex.Extract.isBuiltin : Link.Term -> Boolean
    Unex.Extract.isBuiltin t =
      Text.take 2 (Link.Term.toText t) == "##"

    Unex.Extract.trySerialize : Code ->{IO} Optional Bytes
    Unex.Extract.trySerialize code =
      match catch '(Code.serialize_v3 code) with
        Right bs -> Some bs
        Left _   -> None

    Unex.Extract.walk : [Link.Term] -> [Link.Term] ->{IO, Exception} [Link.Term]
    Unex.Extract.walk seen frontier = match frontier with
      []      -> seen
      t +: ts ->
        if List.contains t seen then Unex.Extract.walk seen ts
        else if Unex.Extract.isBuiltin t then Unex.Extract.walk (t +: seen) ts
        else match Code.lookup t with
          None      -> Unex.Extract.walk (t +: seen) ts
          Some code ->
            match Unex.Extract.trySerialize code with
              None -> Unex.Extract.walk (t +: seen) (ts List.++ Code.dependencies code)
              Some bs ->
                path = FilePath ("#{out_dir}/" Text.++ Link.Term.toText t Text.++ ".code")
                FilePath.writeFile path bs
                Unex.Extract.walk (t +: seen) (ts List.++ Code.dependencies code)

    Unex.Extract.main : '{IO, Exception} ()
    Unex.Extract.main = do
      v = Value.value #{entry_point}
      FilePath.writeFile (FilePath "#{out_dir}/root.value") (Value.serialize_v4 v)
      seen = Unex.Extract.walk [] (Value.dependencies v)
      manifest = Text.join "\\n" (List.map Link.Term.toText seen)
      FilePath.writeFileUtf8 (FilePath "#{out_dir}/manifest.txt") manifest
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
