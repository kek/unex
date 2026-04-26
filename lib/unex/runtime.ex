defmodule Unex.Runtime do
  @moduledoc """
  Manages a persistent UCM codebase for server-side compilation.

  On deploy, pulls a project from Unison Share into the local codebase,
  compiles the entry point to .uc bytecode, and returns the bytes.
  """

  use GenServer

  require Logger

  # Single deploy currently runs ~50–70s end-to-end (extractor walk,
  # name-hash dump, per-name view source). Concurrent deploys serialize
  # through this GenServer, so the queued-caller budget needs to fit a
  # few stacked deploys before the call times out.
  @compile_timeout 600_000

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
        Logger.info("Runtime.extract: starting #{project}/#{entry_point}")
        t_start = :os.system_time(:millisecond)
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

        Logger.info("Runtime.extract: stage 1/3 — pulling project + walking deps")
        t_walk_start = :os.system_time(:millisecond)

        port =
          Port.open({:spawn_executable, ucm}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["--codebase", codebase_path]
          ])

        send(port, {self(), {:command, commands}})
        output = collect_output(port, "", @compile_timeout)

        Logger.info(
          "Runtime.extract: stage 1/3 done in #{:os.system_time(:millisecond) - t_walk_start}ms"
        )

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
              Logger.warning("Runtime.extract: parse_view_output returned nil for #{entry_point}")
            end

            manifest_hashes = String.split(manifest, "\n", trim: true)
            manifest_set = MapSet.new(manifest_hashes, &normalize_hash/1)

            Logger.info("Runtime.extract: stage 2/3 — enumerating + resolving names")
            t_names_start = :os.system_time(:millisecond)

            %{sources: term_sources, names: hash_to_name} =
              collect_named_term_sources(ucm, codebase_path, out_dir, manifest_set)

            Logger.info(
              "Runtime.extract: stage 2-3 done in #{:os.system_time(:millisecond) - t_names_start}ms — term_sources cached: #{map_size(term_sources)} of #{length(manifest_hashes)} manifest entries"
            )

            Logger.info(
              "Runtime.extract: #{project}/#{entry_point} complete in #{:os.system_time(:millisecond) - t_start}ms"
            )

            {:ok,
             %{
               root_value: root_value,
               codes: codes,
               source: source,
               deps: deps,
               term_sources: term_sources,
               names: hash_to_name
             }}
          else
            {:error, "extraction failed. UCM output:\n#{output}"}
          end
        after
          File.rm_rf!(out_dir)
        end
    end
  end

  # Opens a fresh UCM session, enumerates every named term in the project's
  # local namespace via `find`, looks up each name's runtime hash via a
  # generated Unison program (`Link.Term.toText (termLink <name>)`), then
  # `view`s each name and indexes the resulting source by hash. Returns
  # `%{normalized_hash => source_text}` for every name whose hash appears
  # in `manifest_set`.
  #
  # Why all this? UCM's `view #<hash>` only resolves hashes registered in
  # the codebase's name map. The hashes we get from `Code.dependencies` are
  # often bytecode-level sub-references (anonymous lambdas, component
  # fragments) UCM can't address by hash — but every NAMED term in the
  # project IS view-able by name. So we go name-first and join with the
  # manifest by hash.
  defp collect_named_term_sources(ucm, codebase_path, out_dir, %MapSet{} = manifest_set) do
    t_enum = :os.system_time(:millisecond)
    names = enumerate_local_names(ucm, codebase_path)

    Logger.info(
      "Runtime.extract: enumerated #{length(names)} named terms in project (#{:os.system_time(:millisecond) - t_enum}ms)"
    )

    if names == [] do
      %{sources: %{}, names: %{}}
    else
      t_dump = :os.system_time(:millisecond)
      name_to_hash = lookup_name_hashes(ucm, codebase_path, out_dir, names)

      Logger.info(
        "Runtime.extract: resolved #{map_size(name_to_hash)}/#{length(names)} name → hash entries (#{:os.system_time(:millisecond) - t_dump}ms)"
      )

      # Keep only names whose hash is in the manifest — no point fetching
      # source for terms the deployed Value doesn't actually depend on.
      relevant =
        name_to_hash
        |> Enum.filter(fn {_name, hash} -> MapSet.member?(manifest_set, hash) end)
        |> Map.new()

      Logger.info(
        "Runtime.extract: #{map_size(relevant)} of those names are reachable from the deploy"
      )

      hash_to_name =
        Enum.reduce(relevant, %{}, fn {name, hash}, acc -> Map.put(acc, hash, name) end)

      # Skip names whose hash is already in SourceCache from a prior deploy —
      # the source is content-addressed by hash, so re-viewing is wasted work.
      already_cached = source_cache_keys()

      to_view =
        relevant
        |> Enum.reject(fn {_name, hash} -> MapSet.member?(already_cached, hash) end)
        |> Map.new()

      skipped = map_size(relevant) - map_size(to_view)

      Logger.info(
        "Runtime.extract: stage 3/3 — viewing #{map_size(to_view)} new sources (#{skipped} already cached)"
      )

      t_view = :os.system_time(:millisecond)
      sources_by_name = view_sources(ucm, codebase_path, Map.keys(to_view))

      Logger.info(
        "Runtime.extract: stage 3/3 done in #{:os.system_time(:millisecond) - t_view}ms — got source for #{map_size(sources_by_name)}/#{map_size(to_view)} names"
      )

      sources =
        Enum.reduce(to_view, %{}, fn {name, hash}, acc ->
          case Map.get(sources_by_name, name) do
            nil -> acc
            source -> Map.put(acc, hash, source)
          end
        end)

      %{sources: sources, names: hash_to_name}
    end
  rescue
    err ->
      Logger.warning("Runtime.extract: collect_named_term_sources failed: #{inspect(err)}")
      %{sources: %{}, names: %{}}
  end

  defp source_cache_keys do
    Unex.Cluster.SourceCache.keys()
  catch
    :exit, _ -> MapSet.new()
  end

  # Per-subnamespace name cap. Lib subnamespaces (lib.base, lib.kek_unex_*)
  # can have thousands of definitions; we only need surface APIs for the
  # deployed program. Beyond this cap, names won't get source.
  @per_subns_cap 300

  defp enumerate_local_names(ucm, codebase_path) do
    project_names =
      run_ucm(ucm, codebase_path, "find\n")
      |> ucm_output_blocks()
      |> Enum.flat_map(&parse_find_block/1)

    lib_subs = list_lib_subnamespaces(ucm, codebase_path)

    Logger.info("Runtime.extract: discovered lib subnamespaces: #{Enum.join(lib_subs, ", ")}")

    lib_names =
      Enum.flat_map(lib_subs, fn sub ->
        ns = "lib.#{sub}"

        run_ucm(ucm, codebase_path, "find-in #{ns}\n")
        |> ucm_output_blocks()
        |> Enum.flat_map(&parse_find_block/1)
        |> Enum.take(@per_subns_cap)
        |> Enum.map(&"#{ns}.#{&1}")
      end)

    Enum.uniq(project_names ++ lib_names)
  end

  # Parses output of `ls lib`: lines like `"  N. <name>. (<count> terms)"`.
  # Returns just the namespace names (without the trailing dot).
  defp list_lib_subnamespaces(ucm, codebase_path) do
    run_ucm(ucm, codebase_path, "ls lib\n")
    |> ucm_output_blocks()
    |> Enum.flat_map(fn block ->
      block
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*\d+\.\s+([\w]+)\./u, line) do
          [_, sub] -> [sub]
          _ -> []
        end
      end)
    end)
    |> Enum.uniq()
  end

  # Parses lines from a `find` block. Lines look like:
  #   "1.  Unex.Dispatcher.err : Text ->{Exception} Bytes"
  #   "2.  counter.html : Nat -> Text"
  # Multi-line type signatures wrap with leading whitespace; we only pick up
  # lines where the digit-prefix appears.
  defp parse_find_block(block) do
    block
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      # Restrict to alphanumeric+underscore+dot identifiers. Names with
      # operator chars (`!=`, `+`, `<`, `?`, etc.) confuse Unison's parser
      # when used in `termLink <name>` and we don't have a clean way to
      # quote them. Skip those — they're a small minority.
      case Regex.run(~r/^\s*\d+\.\s+([A-Za-z][\w.]*)\s*:/u, line) do
        [_, name] -> [name]
        _ -> []
      end
    end)
  end

  # Names per chunk. Each chunk becomes its own .u file with a uniquely-named
  # dump function, so one bad chunk's parse error doesn't kill the others.
  # Chunks are loaded and run in a SINGLE UCM session to avoid paying startup
  # cost N times.
  @chunk_size 200

  defp lookup_name_hashes(_ucm, _codebase_path, _out_dir, []), do: %{}

  defp lookup_name_hashes(ucm, codebase_path, out_dir, names) do
    chunks = names |> Enum.chunk_every(@chunk_size) |> Enum.with_index()

    # Each chunk gets a unique dump function name so we can `run` them all
    # in sequence without redefining and clobbering.
    chunks
    |> Enum.each(fn {chunk, idx} ->
      File.write!(Path.join(out_dir, "_namedump_#{idx}.u"), namedump_source(chunk, idx))
    end)

    # Interleave load+run per chunk in one UCM session. If chunk N's load
    # fails to compile, only its run is lost — subsequent chunks still
    # load+run cleanly.
    cmd =
      chunks
      |> Enum.map(fn {_chunk, idx} ->
        path = Path.join(out_dir, "_namedump_#{idx}.u")
        "load #{path}\nrun Unex.NameDump.dump_#{idx}\n"
      end)
      |> Enum.join()

    output = run_ucm(ucm, codebase_path, cmd)
    parse_namedump_output(output)
  end

  defp namedump_source(names, idx) do
    body =
      names
      |> Enum.map(fn n ->
        ~s|        printLine ("#{escape_for_unison(n)}\\t" Text.++ Link.Term.toText (termLink #{n}))|
      end)
      |> Enum.join("\n")

    """
    Unex.NameDump.dump_#{idx} : '{IO, Exception} ()
    Unex.NameDump.dump_#{idx} = do
    #{body}
    """
  end

  defp escape_for_unison(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp parse_namedump_output(output) do
    # UCM may concatenate the first printLine of a `run` block onto the
    # same line as the preceding prompt (`runtime/main> name<TAB>#hash`).
    # Match the `name<TAB>#hash` pattern anywhere in the line.
    output
    |> sanitize_terminal_bytes()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/([A-Za-z][\w.]*)\t#?([a-z0-9]{40,})\b/u, line) do
        [_, name, hash] -> [{name, normalize_hash(hash)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp view_sources(_ucm, _codebase_path, []), do: %{}

  defp view_sources(ucm, codebase_path, names) do
    cmd =
      names
      |> Enum.map(fn n -> "view #{n}\n" end)
      |> Enum.join()

    output = run_ucm(ucm, codebase_path, cmd)
    blocks = ucm_output_blocks(output)

    names
    |> Enum.zip(blocks)
    |> Enum.reduce(%{}, fn {name, block}, acc ->
      case accept_block(block) do
        nil -> acc
        source -> Map.put(acc, name, source)
      end
    end)
  end

  defp run_ucm(ucm, codebase_path, command_string) do
    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase", codebase_path]
      ])

    send(port, {self(), {:command, command_string <> "exit\n"}})
    collect_output(port, "", @compile_timeout)
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
    |> sanitize_terminal_bytes()
    |> String.split(~r/^[^\s>]*>\s*$/m, trim: true)
    # Drop the banner block (everything before the first prompt).
    |> tl_or_empty()
    |> Enum.map(&String.trim/1)
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | rest]), do: rest

  # UCM embeds ANSI color escapes (`\e[…m`) AND readline non-printing markers
  # (SOH `\x01`, STX `\x02`) around styled spans. Both must be removed before
  # pattern-matching on prompt lines.
  defp sanitize_terminal_bytes(text) do
    text
    |> then(&Regex.replace(~r/\e\[[0-9;]*[a-zA-Z]/, &1, ""))
    |> String.replace(<<1>>, "")
    |> String.replace(<<2>>, "")
  end

  defp accept_block(text) do
    cond do
      text == "" -> nil
      String.starts_with?(text, "⚠️") -> nil
      String.contains?(text, "I don't know about") -> nil
      String.contains?(text, "The following names were not found") -> nil
      String.contains?(text, "Check your spelling") -> nil
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
