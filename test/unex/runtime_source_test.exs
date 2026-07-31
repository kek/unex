defmodule Unex.RuntimeSourceTest do
  @moduledoc """
  Tests for how source enters the runtime codebase.

  The point of these is structural. `docs/local-dev.md` §4b argues that a local
  deploy must replace *only* the `pull` line inside `Unex.Runtime.extract/3` —
  because a second extraction path would produce `Value`/`Code` bytes by
  different machinery and drift silently, which has already happened once in
  this repo (`Unex.ConfigResolver` versus `config/runtime.exs`). So the test
  that matters here is not "the file path works" — that is
  `test/integration/deploy_local_file_test.exs`, which asserts hash equality
  against Unison Share — it is "the file path is the same path".
  """

  use ExUnit.Case, async: true

  alias Unex.Runtime

  setup do
    dir = Path.join(System.tmp_dir!(), "unex_source_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "ingest_commands/1" do
    test "a Share source pulls the project" do
      assert Runtime.ingest_commands({:share, "@kek/counter"}) == "pull @kek/counter\n"
    end

    test "a file source loads it and updates, so the definitions land in the codebase" do
      assert Runtime.ingest_commands({:file, "/tmp/counter.u"}) ==
               "load /tmp/counter.u\nupdate\n"
    end
  end

  describe "extract_commands/3 — one parameter, not one new path" do
    test "the two sources produce identical scripts apart from ingestion" do
      extractor = "/tmp/unex_extract_1/_extractor.u"
      entry = "mainCounter"
      share = {:share, "@kek/counter"}
      file = {:file, "/tmp/unex_extract_1/counter.u"}

      share_script = Runtime.extract_commands(share, extractor, entry)
      file_script = Runtime.extract_commands(file, extractor, entry)

      refute share_script == file_script

      assert strip_prefix(share_script, Runtime.ingest_commands(share)) ==
               strip_prefix(file_script, Runtime.ingest_commands(file))
    end

    test "what follows ingestion is the extractor, the walk and the entry-point view" do
      extractor = "/tmp/unex_extract_2/_extractor.u"
      source = {:file, "/tmp/unex_extract_2/counter.u"}

      script = Runtime.extract_commands(source, extractor, "mainCounter")

      assert strip_prefix(script, Runtime.ingest_commands(source)) ==
               "load #{extractor}\nrun Unex.Extract.main\nview mainCounter\nexit\n"
    end
  end

  describe "capture_source?/2" do
    test "a Share deploy captures source, so production behaviour is unchanged" do
      assert Runtime.capture_source?({:share, "@kek/counter"})
    end

    test "a file deploy skips it — 95s of a 101s deploy, for bytes nobody reads" do
      refute Runtime.capture_source?({:file, "/tmp/counter.u"})
    end

    test "either default can be overridden" do
      refute Runtime.capture_source?({:share, "@kek/counter"}, capture_source: false)
      assert Runtime.capture_source?({:file, "/tmp/counter.u"}, capture_source: true)
    end

    test "an unrelated option does not disturb the default" do
      assert Runtime.capture_source?({:share, "@kek/counter"}, timeout: 5)
      refute Runtime.capture_source?({:file, "/tmp/counter.u"}, timeout: 5)
    end
  end

  describe "validate_source/1" do
    test "accepts a Share project" do
      assert Runtime.validate_source({:share, "@kek/counter"}) ==
               {:ok, {:share, "@kek/counter"}}

      assert Runtime.validate_source({:share, "@kek/counter/topic"}) ==
               {:ok, {:share, "@kek/counter/topic"}}
    end

    test "accepts an existing .u file and makes the path absolute", %{dir: dir} do
      path = Path.join(dir, "counter.u")
      File.write!(path, "-- placeholder\n")

      assert {:ok, {:file, ^path}} = Runtime.validate_source({:file, path})
      assert Path.type(path) == :absolute
    end

    test "rejects a missing file rather than handing UCM a load it cannot do", %{dir: dir} do
      missing = Path.join(dir, "nope.u")
      assert {:error, message} = Runtime.validate_source({:file, missing})
      assert message =~ "source file not found"
      assert message =~ missing
    end

    test "rejects a file that is not .u", %{dir: dir} do
      path = Path.join(dir, "counter.txt")
      File.write!(path, "-- nope")

      assert {:error, message} = Runtime.validate_source({:file, path})
      assert message =~ "must be a .u file"
    end

    # Both source forms are interpolated into a newline-delimited UCM command
    # script. A newline is therefore command injection into the session that
    # holds the whole persistent codebase.
    test "rejects a newline in a file path" do
      assert {:error, message} =
               Runtime.validate_source({:file, "/tmp/ok.u\ndelete.namespace lib"})

      assert message =~ "invalid source path"
    end

    test "rejects a newline or a space in a project" do
      assert {:error, _} = Runtime.validate_source({:share, "@kek/counter\ndelete.namespace lib"})
      assert {:error, _} = Runtime.validate_source({:share, "@kek/counter lib"})
    end

    test "rejects anything that is not a known source shape" do
      assert {:error, _} = Runtime.validate_source(:share)
      assert {:error, _} = Runtime.validate_source({:file, 42})
      assert {:error, _} = Runtime.validate_source({:url, "https://example.com/x.u"})
    end
  end

  describe "validate_entry_point/1" do
    test "accepts a dotted identifier" do
      assert Runtime.validate_entry_point("mainCounter") == :ok
      assert Runtime.validate_entry_point("counter.main_2") == :ok
    end

    test "rejects anything that could carry a UCM command or Unison syntax" do
      assert {:error, _} = Runtime.validate_entry_point("main\nexit")
      assert {:error, _} = Runtime.validate_entry_point("main counter")
      assert {:error, _} = Runtime.validate_entry_point("main;drop")
      assert {:error, _} = Runtime.validate_entry_point(nil)
    end
  end

  defp strip_prefix(script, prefix) do
    assert String.starts_with?(script, prefix)
    String.replace_prefix(script, prefix, "")
  end
end
