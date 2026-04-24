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

            files = File.ls!(out_dir)

            codes =
              files
              |> Enum.filter(&String.ends_with?(&1, ".code"))
              |> Enum.into(%{}, fn fname ->
                term_text = String.replace_suffix(fname, ".code", "")
                {term_text, File.read!(Path.join(out_dir, fname))}
              end)

            deps =
              files
              |> Enum.filter(&String.ends_with?(&1, ".deps"))
              |> Enum.into(%{}, fn fname ->
                key = String.replace_suffix(fname, ".deps", "")

                dep_list =
                  Path.join(out_dir, fname)
                  |> File.read!()
                  |> String.split("\n", trim: true)

                {key, dep_list}
              end)

            manifest_path = Path.join(out_dir, "manifest.txt")
            manifest = if File.exists?(manifest_path), do: File.read!(manifest_path), else: ""

            Logger.info(
              "Runtime.extract: walked #{length(String.split(manifest, "\n", trim: true))} terms, wrote #{map_size(codes)} codes, #{map_size(deps)} dep entries"
            )

            source = parse_view_output(output, entry_point)

            if source do
              Logger.info(
                "Runtime.extract: entry-point source cached: #{byte_size(source)} bytes"
              )
            else
              dump_path =
                Path.join(System.tmp_dir!(), "unex_extract_debug_#{:os.system_time(:second)}.log")

              File.write!(dump_path, output)
              view_markers = :binary.matches(output, "view ") |> length()

              Logger.warning(
                "Runtime.extract: parse_view_output returned nil. #{view_markers} 'view ' markers in output. Full UCM output dumped to: #{dump_path}"
              )
            end

            manifest_hashes = String.split(manifest, "\n", trim: true)
            term_sources = collect_term_sources(ucm, codebase_path, manifest_hashes)

            Logger.info(
              "Runtime.extract: term_sources cached: #{map_size(term_sources)} of #{length(manifest_hashes)} manifest entries"
            )

            {:ok,
             %{
               root_value: root_value,
               codes: codes,
               source: source,
               deps: deps,
               term_sources: term_sources
             }}
          else
            {:error, "extraction failed. UCM output:\n#{output}"}
          end
        after
          File.rm_rf!(out_dir)
        end
    end
  end

  # Opens a second UCM session and runs `view #<hash>` for every hash in the
  # manifest. Parses each view block and returns a map of
  # `normalized_hash => source_text`. Failures are logged and swallowed —
  # deploys still succeed on parser/timeout errors.
  defp collect_term_sources(_ucm, _codebase_path, []), do: %{}

  defp collect_term_sources(ucm, codebase_path, hashes) when is_list(hashes) do
    try do
      port =
        Port.open({:spawn_executable, ucm}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["--codebase", codebase_path]
        ])

      view_commands =
        hashes
        |> Enum.map(fn h -> "view #{h}\n" end)
        |> Enum.join()

      send(port, {self(), {:command, view_commands <> "exit\n"}})
      views_output = collect_output(port, "", @compile_timeout)

      parse_all_view_outputs(views_output, hashes)
    rescue
      err ->
        Logger.warning("Runtime.extract: second UCM session failed: #{inspect(err)}")
        %{}
    end
  end

  @doc false
  # Strips ANSI color escape sequences and splits a UCM transcript into the
  # list of output blocks between successive prompt lines. UCM does NOT echo
  # commands to its stdout; it prints a prompt line (e.g. `runtime/main> `),
  # reads a command, then prints that command's output, then the next prompt.
  # So for commands [c1, c2, c3, c4] the transcript is:
  #
  #   <banner>
  #   prompt>
  #   <c1 output>
  #   prompt>
  #   <c2 output>
  #   ...
  #
  # This returns a list of trimmed blocks in command order, dropping the banner.
  def ucm_output_blocks(output) when is_binary(output) do
    output
    |> strip_ansi()
    |> String.split(~r/^[^\s>]*>\s*$/m, trim: true)
    # Drop the banner block (everything before the first prompt).
    |> tl_or_empty()
    |> Enum.map(&String.trim/1)
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | rest]), do: rest

  defp strip_ansi(text), do: Regex.replace(~r/\e\[[0-9;]*[a-zA-Z]/, text, "")

  defp accept_block(text) do
    cond do
      text == "" -> nil
      String.contains?(text, "I don't know about") -> nil
      Regex.match?(~r/\berror:/i, text) -> nil
      true -> text
    end
  end

  @doc false
  # Given the UCM transcript from a session that ran one or more `view #<hash>`
  # commands (optionally followed by `exit`), returns a map of
  # `normalized_hash => source_text` by zipping hashes with blocks in order.
  # Keys omit the leading `#`. Blocks that are empty or look like errors are
  # skipped.
  def parse_all_view_outputs(output, hashes)
      when is_binary(output) and is_list(hashes) do
    blocks = ucm_output_blocks(output)

    hashes
    |> Enum.zip(blocks)
    |> Enum.reduce(%{}, fn {hash, block}, acc ->
      case accept_block(block) do
        nil -> acc
        source -> Map.put(acc, normalize_hash(hash), source)
      end
    end)
  end

  defp normalize_hash("#" <> rest), do: rest
  defp normalize_hash(hash), do: hash

  @doc false
  # Parses the session-1 transcript (pull / load / run / view <entry_point>
  # [/exit]) and returns the view's output block. The view is always the last
  # command before exit, so the last output block in the transcript is the
  # pretty-printed source. Returns nil if no non-empty block is present.
  def parse_view_output(output, _entry_point) when is_binary(output) do
    output
    |> ucm_output_blocks()
    |> Enum.reverse()
    |> Enum.find_value(&accept_block/1)
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

    Unex.Extract.writeDeps : Text -> [Link.Term] ->{IO, Exception} ()
    Unex.Extract.writeDeps key deps =
      depsText = Text.join "\\n" (List.map Link.Term.toText deps)
      depsPath = FilePath ("#{out_dir}/" Text.++ key Text.++ ".deps")
      FilePath.writeFileUtf8 depsPath depsText

    Unex.Extract.walk : [Link.Term] -> [Link.Term] ->{IO, Exception} [Link.Term]
    Unex.Extract.walk seen frontier = match frontier with
      []      -> seen
      t +: ts ->
        if List.contains t seen then Unex.Extract.walk seen ts
        else if Unex.Extract.isBuiltin t then Unex.Extract.walk (t +: seen) ts
        else match Code.lookup t with
          None      -> Unex.Extract.walk (t +: seen) ts
          Some code ->
            deps = Code.dependencies code
            Unex.Extract.writeDeps (Link.Term.toText t) deps
            match Unex.Extract.trySerialize code with
              None -> Unex.Extract.walk (t +: seen) (ts List.++ deps)
              Some bs ->
                path = FilePath ("#{out_dir}/" Text.++ Link.Term.toText t Text.++ ".code")
                FilePath.writeFile path bs
                Unex.Extract.walk (t +: seen) (ts List.++ deps)

    Unex.Extract.main : '{IO, Exception} ()
    Unex.Extract.main = do
      v = Value.value #{entry_point}
      FilePath.writeFile (FilePath "#{out_dir}/root.value") (Value.serialize_v4 v)
      rootDeps = Value.dependencies v
      Unex.Extract.writeDeps "root" rootDeps
      seen = Unex.Extract.walk [] rootDeps
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
