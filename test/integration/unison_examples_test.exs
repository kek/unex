defmodule Unex.Integration.UnisonExamplesTest do
  @moduledoc """
  End-to-end tests: verify that the example .u programs in unison/Examples/
  compile and run correctly against a live Unex server.

  Each test concatenates the full Unison ability library + an example program
  into a single source string, substitutes the test port, and runs via Unex.eval.
  """
  use ExUnit.Case, async: false

  @test_port 4043

  setup_all do
    mnesia_dir =
      Path.join(
        System.tmp_dir!(),
        "unex_examples_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(mnesia_dir)
    Unex.Storage.Schema.init(mnesia_dir)

    {:ok, bandit_pid} = Bandit.start_link(plug: Unex.API.Router, port: @test_port)

    on_exit(fn ->
      Process.exit(bandit_pid, :normal)
      :mnesia.stop()
      File.rm_rf!(mnesia_dir)
    end)

    {:ok, port: @test_port}
  end

  defp project_root, do: Path.join(__DIR__, "../..") |> Path.expand()

  defp load_library_source do
    # Concatenate all library .u files in dependency order:
    # Helpers first (shared HTTP utils), then each ability, then Main combinator
    files = [
      "unison/Unex/Http/Helpers.u",
      "unison/Unex/Storage.u",
      "unison/Unex/Config.u",
      "unison/Unex/Blobs.u",
      "unison/Unex/Scratch.u",
      "unison/Unex/Log.u",
      "unison/Unex/Remote.u",
      "unison/Unex/Services.u",
      "unison/Main.u"
    ]

    files
    |> Enum.map(fn f -> File.read!(Path.join(project_root(), f)) end)
    |> Enum.join("\n\n")
  end

  defp load_example(name) do
    File.read!(Path.join(project_root(), "unison/Examples/#{name}.u"))
  end

  defp build_source(example_name, port) do
    lib = load_library_source()
    example = load_example(example_name)

    (lib <> "\n\n" <> example)
    |> String.replace("http://localhost:4040", "http://127.0.0.1:#{port}")
  end

  @tag timeout: 600_000
  test "BasicStorage example compiles and runs", %{port: port} do
    source = build_source("BasicStorage", port)

    result = Unex.eval(source, timeout: 300_000, entry: "Examples.BasicStorage.main")

    case result do
      {:ok, r} ->
        stdout = Unex.UCM.Output.strip_ansi(r.stdout)
        assert stdout =~ "Alice:", "Expected 'Alice:' in output, got:\n#{stdout}"
        assert stdout =~ "Visitors:", "Expected 'Visitors:' in output, got:\n#{stdout}"
        assert stdout =~ "Done!", "Expected 'Done!' in output, got:\n#{stdout}"

      {:error, r} ->
        flunk("BasicStorage failed (exit #{r.exit_code}):\n#{r.stdout}\n#{r.stderr}")
    end
  end

  @tag timeout: 600_000
  test "ConfigAndSecrets example compiles and runs", %{port: port} do
    source = build_source("ConfigAndSecrets", port)

    result = Unex.eval(source, timeout: 300_000, entry: "Examples.ConfigAndSecrets.main")

    case result do
      {:ok, r} ->
        stdout = Unex.UCM.Output.strip_ansi(r.stdout)
        assert stdout =~ "Prod API key:", "Expected 'Prod API key:' in output, got:\n#{stdout}"
        assert stdout =~ "Done!", "Expected 'Done!' in output, got:\n#{stdout}"

      {:error, r} ->
        flunk("ConfigAndSecrets failed (exit #{r.exit_code}):\n#{r.stdout}\n#{r.stderr}")
    end
  end

  @tag timeout: 600_000
  test "FullApp example compiles and runs", %{port: port} do
    source = build_source("FullApp", port)

    result = Unex.eval(source, timeout: 300_000, entry: "Examples.FullApp.main")

    case result do
      {:ok, r} ->
        stdout = Unex.UCM.Output.strip_ansi(r.stdout)
        assert stdout =~ "Item:", "Expected 'Item:' in output, got:\n#{stdout}"
        assert stdout =~ "All done!", "Expected 'All done!' in output, got:\n#{stdout}"

      {:error, r} ->
        flunk("FullApp failed (exit #{r.exit_code}):\n#{r.stdout}\n#{r.stderr}")
    end
  end
end
