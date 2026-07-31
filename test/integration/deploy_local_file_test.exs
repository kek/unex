defmodule Unex.Integration.DeployLocalFileTest do
  @moduledoc """
  The validation `docs/local-dev.md` §7 specifies for slice 2: a local `.u` file
  must produce **the same root hash** as the Unison Share path does for the same
  code.

  That assertion is the whole argument. Anything can deploy a file; what has to
  be true is that `mix unex.deploy` is a different *door into the same machine*
  rather than a parallel implementation, because a parallel one would produce
  `Value`/`Code` bytes by different machinery and drift silently. Hash equality
  is the only check that cannot be satisfied by a lookalike.

  The two halves run against **separate runtime codebases**, and the file half
  runs against a codebase that has never seen `@kek/counter`. Otherwise the file
  half could be resolving names that the Share pull had already put there, and
  the test would prove nothing.

  Requires:
    - `ucm` on PATH
    - network access to Unison Share (for the Share half, and for library
      installs if there is no codebase to copy)

  No dispatcher is needed: this test asserts what deploy *produces*, not what
  calling it returns. `test/integration/service_lifecycle_test.exs` covers the
  call path.
  """

  use ExUnit.Case, async: false

  alias Unex.Cluster.HashCache
  alias Unex.Runtime

  @moduletag :integration
  @moduletag timeout: 1_800_000

  @share_project "@kek/counter"
  @entry_point "mainCounter"

  # A faithful transcription of @kek/counter's `mainCounter` closure, as
  # `ucm view` renders it. Unison hashes the elaborated AST, not this text, so
  # layout and comments are free — but the expressions and the names they
  # resolve to are not, which is exactly the property under test.
  @local_source ~S"""
  counter.html : Nat -> Text
  counter.html n =
    use Text ++
    "<!DOCTYPE html><html><body style='font-family:system-ui;text-align:center;padding:4em'>"
      ++ "<h1>Visitory #"
      ++ Nat.toText n
      ++ "</h1>"
      ++ "<p>Powered by Unex?!!!</p>"
      ++ "</body></html>"

  counter : '{IO, Exception, Storage} ()
  counter = do
    use Nat +
    createDatabase "counter"
    current = match readCell "counter" "hits" with
      Some n -> Optional.getOrElse 0 (Nat.fromText n)
      None   -> 0
    new = current + 1
    writeCell "counter" "hits" (Nat.toText new)
    printLine (counter.html new)

  mainCounter : '{IO, Exception} ()
  mainCounter = Unex.main counter
  """

  setup_all do
    base =
      Path.join(
        System.tmp_dir!(),
        "unex_hash_equivalence_#{:erlang.unique_integer([:positive])}"
      )

    file_dir = Path.join(base, "from-file")
    share_dir = Path.join(base, "from-share")
    Enum.each([file_dir, share_dir], &File.mkdir_p!/1)

    seed_codebases(file_dir, share_dir)

    source_path = Path.join(base, "counter.u")
    File.write!(source_path, @local_source)

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, file_dir: file_dir, share_dir: share_dir, source_path: source_path}
  end

  test "a local file and Unison Share produce byte-identical deploys", ctx do
    # File first, on a codebase that has never seen the Share project. If this
    # ran second it could be resolving names the pull had already installed.
    from_file =
      with_data_dir(ctx.file_dir, fn ->
        extract!({:file, ctx.source_path})
      end)

    from_share =
      with_data_dir(ctx.share_dir, fn ->
        extract!({:share, @share_project})
      end)

    file_hash = HashCache.hash_of(from_file.root_value)
    share_hash = HashCache.hash_of(from_share.root_value)

    assert file_hash == share_hash, """
    The local file did not produce the Share deploy's root hash.

      from #{ctx.source_path}
        #{file_hash}  (#{byte_size(from_file.root_value)} bytes)

      from #{@share_project}
        #{share_hash}  (#{byte_size(from_share.root_value)} bytes)

    Either the transcribed source is not the same code, or the two codebases
    resolved a name to different library versions (docs/local-dev.md §4b), or
    the file path is no longer the same extraction path.
    """

    # Stronger than the root hash on its own: the whole transitive closure the
    # dispatcher will fetch is the same bytes under the same keys.
    assert Enum.sort(Map.keys(from_file.codes)) == Enum.sort(Map.keys(from_share.codes)),
           "the two deploys walked different closures"

    assert from_file.codes == from_share.codes,
           "the two deploys serialized the same terms to different bytes"

    # And the deliberate difference: the file deploy skipped the dashboard
    # source-capture stages, which is 94% of deploy time and — as the equality
    # above just demonstrated — changes nothing about the deployed bytes.
    assert from_file.term_sources == %{},
           "a file deploy should skip source capture by default"

    refute from_share.term_sources == %{},
           "a Share deploy should still capture source"
  end

  test "capturing source on a file deploy does not change what is deployed", ctx do
    without =
      with_data_dir(ctx.file_dir, fn ->
        extract!({:file, ctx.source_path})
      end)

    with_capture =
      with_data_dir(ctx.file_dir, fn ->
        extract!({:file, ctx.source_path}, capture_source: true)
      end)

    assert HashCache.hash_of(without.root_value) ==
             HashCache.hash_of(with_capture.root_value)

    assert without.codes == with_capture.codes
    refute with_capture.term_sources == %{}
  end

  defp extract!(source, opts \\ []) do
    case Runtime.extract(source, @entry_point, opts) do
      {:ok, extract} -> extract
      {:error, reason} -> flunk("extract from #{inspect(source)} failed:\n#{reason}")
    end
  end

  # `Unex.Runtime` reads `:data_dir` once, at init, and runs as a singleton under
  # `Unex.Supervisor`. Pointing it at another codebase therefore means restarting
  # that one child rather than reaching inside it.
  defp with_data_dir(dir, fun) do
    previous = Application.get_env(:unex, :data_dir)
    swap_runtime(dir)

    try do
      fun.()
    after
      swap_runtime(previous)
    end
  end

  defp swap_runtime(dir) do
    :ok = Supervisor.terminate_child(Unex.Supervisor, Unex.Runtime)

    if dir do
      Application.put_env(:unex, :data_dir, dir)
    else
      Application.delete_env(:unex, :data_dir)
    end

    {:ok, _pid} = Supervisor.restart_child(Unex.Supervisor, Unex.Runtime)
    :ok
  end

  # Installing @unison/base, @unison/http and @kek/unex from Share takes minutes
  # per codebase. `Unex.Runtime.init/1` will do it when a codebase is absent, but
  # if this checkout already has one, copy it — the point of the test is the
  # hashes, not the library installs.
  defp seed_codebases(file_dir, share_dir) do
    template =
      Application.get_env(:unex, :data_dir, "data")
      |> Path.join("runtime_codebase")
      |> Path.expand()

    if File.dir?(template) do
      Enum.each([file_dir, share_dir], fn dir ->
        File.cp_r!(template, Path.join(dir, "runtime_codebase"))
      end)
    end
  end
end
