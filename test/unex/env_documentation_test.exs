defmodule Unex.EnvDocumentationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `UNEX_*` environment variables against drifting out of the README.

  This exists because an audit of the ten variables exported by the repo's
  (untracked) `.envrc` found five that the code reads but nothing documented,
  and one — `UNEX_ADMIN_PASSWORD` — that only ever existed in that shell file
  and in a sentence describing it. A live variable nobody wrote down is a
  deployment failure waiting to happen, and setup that lives only in an
  untracked file cannot be reviewed. So the check runs in CI instead.
  """

  # Variables the server injects into its own subprocesses. An operator never
  # sets these, so they belong here rather than in the README's config tables.
  @internal ~w(UNEX_DISPATCHER_PORT)

  # Where configuration is actually read. Deliberately excludes docs/ (prose
  # mentions are not reads) and test/ (fixtures are not reads).
  @source_globs ["config/*.exs", "lib/**/*.ex", "unison/**/*.u"]

  defp read_sites do
    @source_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, lineno} ->
        line
        |> extract_names()
        |> Enum.map(&{&1, "#{path}:#{lineno}"})
      end)
    end)
    |> Enum.group_by(fn {name, _site} -> name end, fn {_name, site} -> site end)
  end

  # Every shape this codebase reads an env var in. `System.put_env` is
  # deliberately absent: setting a variable is not reading one.
  defp extract_names(line) do
    patterns = [
      # System.get_env("X") / System.fetch_env("X") / System.fetch_env!("X")
      ~r/System\.(?:get_env|fetch_env!?)\(\s*"(UNEX_[A-Z0-9_]+)"/,
      # the `get.`/`get_int.` closures in config/runtime.exs
      ~r/\bget(?:_int)?\.\(\s*"(UNEX_[A-Z0-9_]+)"/,
      # Unison: getEnv "X" / IO.getEnv "X"
      ~r/getEnv\s+"(UNEX_[A-Z0-9_]+)"/
    ]

    Enum.flat_map(patterns, fn re ->
      Regex.scan(re, line) |> Enum.map(fn [_full, name] -> name end)
    end)
  end

  defp documented do
    "README.md"
    |> File.read!()
    |> then(&Regex.scan(~r/^\|\s*`(UNEX_[A-Z0-9_]+)`/m, &1))
    |> Enum.map(fn [_full, name] -> name end)
    |> MapSet.new()
  end

  test "every UNEX_* variable the code reads is documented in the README" do
    sites = read_sites()
    documented = documented()

    undocumented =
      sites
      |> Map.drop(@internal)
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(documented, &1))
      |> Enum.sort()

    assert undocumented == [],
           """
           These UNEX_* variables are read by the code but are not in the
           README's configuration tables:

           #{Enum.map_join(undocumented, "\n", fn name -> "  #{name}\n" <> Enum.map_join(sites[name], "\n", &"      read at #{&1}") end)}

           Add a row for each, or add it to @internal in this test if the
           server injects it into its own subprocesses.
           """
  end

  test "the README documents no UNEX_* variable that nothing reads" do
    read = read_sites() |> Map.keys() |> MapSet.new()
    internal = MapSet.new(@internal)

    stale =
      documented()
      |> Enum.reject(&(MapSet.member?(read, &1) or MapSet.member?(internal, &1)))
      |> Enum.sort()

    assert stale == [],
           """
           The README documents these UNEX_* variables, but nothing in
           config/, lib/ or unison/ reads them. Either they are dead and the
           rows should go, or the code that read them was removed:

           #{Enum.map_join(stale, "\n", &"  #{&1}")}
           """
  end

  test "UNEX_ADMIN_PASSWORD is not read anywhere" do
    # It never was: `git log --all -S UNEX_ADMIN_PASSWORD` finds only drafts of
    # the docs/local-dev.md sentence describing it. If this ever fails, the
    # name has come back to life and needs documenting.
    refute "UNEX_ADMIN_PASSWORD" in Map.keys(read_sites())
  end
end
