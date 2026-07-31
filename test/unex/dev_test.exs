defmodule Unex.DevTest do
  @moduledoc """
  Covers the preflight logic `mix unex.dev` depends on.

  The load-bearing case is `bundle_status/2` refusing a bundle built by a
  different UCM. That is not a hypothetical: this repo's Dockerfile pins UCM
  1.2.0, a developer machine may well run something newer, and UCM flatly
  refuses to execute a mismatched `.uc`. Without this check the failure arrives
  as a ten-second accept timeout per dispatcher worker followed by every service
  call returning `:dispatcher_not_started`.
  """

  use ExUnit.Case, async: true

  alias Unex.Dev

  # The first 39 bytes of a real bundle produced by `ucm compile` under UCM
  # 1.2.0 — a big-endian 32-bit length (0x23 = 35) then the version text. Kept
  # as a literal so the parser is pinned to a format that was observed, not
  # assumed.
  @real_header <<0, 0, 0, 0x23>> <> "release/1.2.0 (built on 2026-04-14)"

  defp bundle(contents) do
    path = Path.join(System.tmp_dir!(), "unex_dev_test_#{System.unique_integer([:positive])}.uc")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "bundle_version/1" do
    test "reads the version out of a real .uc header" do
      path = bundle(@real_header <> :crypto.strong_rand_bytes(64))

      assert Dev.bundle_version(path) == {:ok, "release/1.2.0 (built on 2026-04-14)"}
    end

    test "reports a missing file" do
      assert Dev.bundle_version(Path.join(System.tmp_dir!(), "no-such-bundle.uc")) ==
               {:error, :missing}
    end

    test "rejects a file that is not a compiled bundle" do
      path = bundle("this is not unison bytecode")

      assert Dev.bundle_version(path) == {:error, :unrecognized_format}
    end

    test "rejects an absurd length prefix instead of slicing gigabytes" do
      path = bundle(<<0xFF, 0xFF, 0xFF, 0xFF>> <> "release/1.2.0")

      assert Dev.bundle_version(path) == {:error, :unrecognized_format}
    end

    test "rejects a header that claims more bytes than the file holds" do
      path = bundle(<<0, 0, 0, 0x23>> <> "release/1.2")

      assert Dev.bundle_version(path) == {:error, :unrecognized_format}
    end
  end

  describe "release_number/1" do
    test "extracts the bare release number" do
      assert Dev.release_number("release/1.2.0 (built on 2026-04-14)") == {:ok, "1.2.0"}
      assert Dev.release_number("release/1.3.0 (built on 2026-05-13)") == {:ok, "1.3.0"}
    end

    test "fails on text with no version in it" do
      assert Dev.release_number("release/main") == {:error, :unrecognized_format}
    end
  end

  describe "bundle_status/2" do
    test "accepts a bundle built by the running UCM" do
      path = bundle(@real_header)

      assert Dev.bundle_status(path, "1.2.0") == {:ok, "release/1.2.0 (built on 2026-04-14)"}
    end

    test "demands a rebuild when the bundle was built by a different UCM" do
      path = bundle(@real_header)

      assert Dev.bundle_status(path, "1.3.0") == {:rebuild, {:version_mismatch, "1.2.0", "1.3.0"}}
    end

    test "demands a rebuild when there is no bundle yet" do
      path = Path.join(System.tmp_dir!(), "no-such-bundle.uc")

      assert Dev.bundle_status(path, "1.3.0") == {:rebuild, :missing}
    end

    test "demands a rebuild when the file is not a bundle" do
      path = bundle("junk")

      assert Dev.bundle_status(path, "1.3.0") == {:rebuild, :unrecognized_format}
    end
  end

  describe "explain/1" do
    test "names both versions in a mismatch, so the message is actionable" do
      message = Dev.explain({:version_mismatch, "1.2.0", "1.3.0"})

      assert message =~ "1.2.0"
      assert message =~ "1.3.0"
    end

    test "covers the other rebuild reasons" do
      assert Dev.explain(:missing) =~ "no dispatcher bundle"
      assert Dev.explain(:unrecognized_format) =~ "not a compiled Unison bundle"
      assert Dev.explain(:eacces) =~ "could not be read"
    end
  end

  describe "credential file" do
    test "round-trips through render and parse" do
      vars = %{"UNEX_SECRET" => "abc+/=", "UNEX_CONFIG_KEY" => "def=="}

      assert vars |> Dev.render_env() |> Dev.parse_env() == vars
    end

    test "ignores comments and blank lines" do
      text = """
      # a comment
      UNEX_SECRET=s3cret

      UNEX_CONFIG_KEY=k3y
      """

      assert Dev.parse_env(text) == %{"UNEX_SECRET" => "s3cret", "UNEX_CONFIG_KEY" => "k3y"}
    end

    test "keeps base64 padding in values rather than splitting on every =" do
      assert Dev.parse_env("UNEX_CONFIG_KEY=TZ54jSFa5PnTsG3K12Lj1y/q6mjGpCAdp2qMbSzR21o=") ==
               %{"UNEX_CONFIG_KEY" => "TZ54jSFa5PnTsG3K12Lj1y/q6mjGpCAdp2qMbSzR21o="}
    end

    test "reading an absent file yields no variables" do
      assert Dev.read_env_file(Path.join(System.tmp_dir!(), "no-such-dev.env")) == %{}
    end

    test "writes owner-only, because it holds the API secret and the encryption key" do
      dir = Path.join(System.tmp_dir!(), "unex_dev_env_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Dev.env_file(dir)

      :ok = Dev.write_env_file!(path, %{"UNEX_SECRET" => "s3cret"})

      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Dev.read_env_file(path) == %{"UNEX_SECRET" => "s3cret"}
    end

    test "env_file/1 lives inside the data directory" do
      assert Dev.env_file("/tmp/unex-dev") == "/tmp/unex-dev/dev.env"
    end
  end

  describe "banner/1" do
    setup do
      {:ok,
       info: %{
         api_url: "http://localhost:4040",
         secret: "s3cret",
         data_dir: "/tmp/unex-dev",
         ucm_path: "/opt/homebrew/bin/ucm",
         ucm_version: "release/1.3.0",
         dispatcher_path: "/tmp/unex-dev/dispatcher.uc",
         dispatcher_version: "release/1.3.0 (built on 2026-05-13)",
         pool_size: 1,
         node: :nonode@nohost,
         dashboard: nil
       }}
    end

    test "gives the developer everything needed to point a program at the node", %{info: info} do
      text = Dev.banner(info)

      assert text =~ "http://localhost:4040"
      assert text =~ "export UNEX_URL=http://localhost:4040"
      assert text =~ "export UNEX_SECRET=s3cret"
      assert text =~ "/tmp/unex-dev"
    end

    test "states the divergences from production out loud", %{info: info} do
      text = Dev.banner(info)

      assert text =~ "release/1.3.0"
      assert text =~ "NOT replicated"
      assert text =~ "pool of 1"
    end

    test "says how to turn the dashboard on when it is off", %{info: info} do
      assert Dev.banner(info) =~ "--dashboard"
    end

    test "shows the dashboard URL when it is on", %{info: info} do
      text = Dev.banner(%{info | dashboard: "http://localhost:4041 (basic auth: admin)"})

      assert text =~ "http://localhost:4041"
      refute text =~ "off (pass --dashboard"
    end
  end
end
