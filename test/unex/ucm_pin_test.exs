defmodule Unex.UCMPinTest do
  @moduledoc """
  The UCM release number has to appear in more than one place — Docker cannot
  read a file to resolve an `ARG` default, and a GitHub Actions `run:` block
  needs it to build a download URL. That duplication once produced a three-way
  straddle: the Dockerfile pinned 1.2.0, CI installed 1.1.1, and the developer's
  machine ran 1.3.0, with nothing anywhere comparing them.

  It is not a cosmetic inconsistency. `ucm run.compiled` refuses a `.uc` bundle
  built by a different UCM ("I can't run this compiled program since it works
  with a different version of Unison than the one you're running"), so a
  straddle means a green CI run proves nothing about the image and nothing about
  production.

  `scripts/assert-ucm-version.sh` catches it at *build* time, against the
  installed binary and the compiled bundle. These tests catch it in the ordinary
  `mix test test/unex` gate, from the files alone, so drift is named on the
  commit that introduces it rather than in a Docker build nobody ran.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  defp read!(relative), do: File.read!(Path.join(@repo_root, relative))

  defp pinned_version do
    read!(".ucm-version") |> String.trim()
  end

  test ".ucm-version holds a single bare release number" do
    assert pinned_version() =~ ~r/^\d+\.\d+\.\d+$/,
           """
           .ucm-version must contain exactly one bare X.Y.Z release number \
           (got #{inspect(pinned_version())}). Everything else derives from it.
           """
  end

  test "the Dockerfile's ARG UCM_VERSION default agrees with .ucm-version" do
    dockerfile = read!("Dockerfile")
    pinned = pinned_version()

    defaults =
      Regex.scan(~r/^ARG\s+UCM_VERSION=(\S+)\s*$/m, dockerfile)
      |> Enum.map(fn [_, value] -> value end)

    assert defaults != [],
           "Dockerfile has no `ARG UCM_VERSION=<version>` default to check"

    for value <- defaults do
      assert value == pinned,
             """
             UCM VERSION STRADDLE: Dockerfile has `ARG UCM_VERSION=#{value}` but \
             .ucm-version says #{pinned}.

             .ucm-version is authoritative. A bundle compiled by one UCM refuses \
             to run on another, so this disagreement means the image's dispatcher \
             cannot start: four ten-second accept timeouts, then \
             :dispatcher_not_started on every service call.
             """
    end
  end

  test "CI derives the UCM version from .ucm-version instead of repeating it" do
    workflow = read!(".github/workflows/unex.yml")

    literals =
      Regex.scan(~r/release%2F(\d+\.\d+\.\d+)/, workflow)
      |> Enum.map(fn [_, value] -> value end)

    assert literals == [],
           """
           UCM VERSION STRADDLE: .github/workflows/unex.yml hardcodes UCM \
           #{inspect(literals)} in a download URL.

           This is exactly how CI came to install 1.1.1 while the Dockerfile \
           pinned 1.2.0. Read the number out of .ucm-version instead:

               - name: Resolve pinned UCM version
                 id: ucm
                 run: echo "version=$(tr -d '[:space:]' < .ucm-version)" >> "$GITHUB_OUTPUT"
           """
  end

  test "the build-time guard exists and is executable" do
    path = Path.join(@repo_root, "scripts/assert-ucm-version.sh")
    assert File.exists?(path), "scripts/assert-ucm-version.sh is missing"

    %File.Stat{mode: mode} = File.stat!(path)

    assert Bitwise.band(mode, 0o111) != 0,
           "scripts/assert-ucm-version.sh is not executable"
  end

  test "the guard rejects a declared version that disagrees with the file" do
    # A bite test for the guard itself: hand it a version the file does not
    # hold and require that it fails, and that its message names the straddle.
    # Uses a deliberately wrong number rather than the pinned one so this does
    # not depend on which UCM happens to be installed on the machine running it.
    wrong = "0.0.1"
    refute wrong == pinned_version()

    {output, status} =
      System.cmd("bash", ["scripts/assert-ucm-version.sh", wrong],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    assert status != 0, "the guard accepted a declared version of #{wrong}:\n#{output}"
    assert output =~ "UCM VERSION STRADDLE"
    assert output =~ wrong
    assert output =~ pinned_version()
  end
end
