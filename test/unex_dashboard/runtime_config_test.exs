defmodule Unex.Dashboard.RuntimeConfigTest do
  @moduledoc """
  Evaluates the real `config/runtime.exs` the way a release boot does, so the
  hardening is proven on the actual production path rather than only on the
  function it delegates to.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_config "config/runtime.exs"

  # Every env var runtime.exs reads for the dashboard, so a value left over from
  # the developer's shell cannot decide the outcome of a test.
  @vars [
    "UNEX_CONFIG",
    "UNEX_DASHBOARD",
    "UNEX_DASHBOARD_USER",
    "UNEX_DASHBOARD_PASS",
    "UNEX_DASHBOARD_SECRET"
  ]

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    Enum.each(@vars, &System.delete_env/1)

    # Point at a path that does not exist: runtime.exs then skips both default
    # config-file locations, so this test does not depend on the host's
    # ~/.config/unex/config.exs.
    System.put_env("UNEX_CONFIG", Path.join(System.tmp_dir!(), "unex-no-such-config.exs"))

    :ok
  end

  defp read(env) do
    capture_io(fn ->
      send(self(), {:config, Config.Reader.read!(@runtime_config, env: env, target: :host)})
    end)

    receive do
      {:config, config} -> config[:unex]
    end
  end

  describe "production" do
    test "refuses to boot when the dashboard is enabled with no credentials set" do
      System.put_env("UNEX_DASHBOARD", "1")

      err = assert_raise RuntimeError, fn -> read(:prod) end

      assert err.message =~ "Refusing to boot"
      assert err.message =~ "UNEX_DASHBOARD_USER"
      assert err.message =~ "UNEX_DASHBOARD_PASS"
    end

    test "refuses to boot when only the username is set" do
      System.put_env("UNEX_DASHBOARD", "true")
      System.put_env("UNEX_DASHBOARD_USER", "ops")

      assert_raise RuntimeError, ~r/UNEX_DASHBOARD_PASS is unset/, fn -> read(:prod) end
    end

    test "refuses to boot on the shipped default password" do
      System.put_env("UNEX_DASHBOARD", "1")
      System.put_env("UNEX_DASHBOARD_USER", "admin")
      System.put_env("UNEX_DASHBOARD_PASS", "unex")

      assert_raise RuntimeError, ~r/Refusing to boot/, fn -> read(:prod) end
    end

    test "accepts properly set credentials" do
      System.put_env("UNEX_DASHBOARD", "1")
      System.put_env("UNEX_DASHBOARD_USER", "ops")
      System.put_env("UNEX_DASHBOARD_PASS", "Qx7-strong-and-unique")

      config = read(:prod)

      assert config[:start_dashboard] == true
      assert config[:dashboard_username] == "ops"
      assert config[:dashboard_password] == "Qx7-strong-and-unique"
    end

    test "boots with the dashboard off and does not inherit the compiled-in defaults" do
      config = read(:prod)

      assert config[:start_dashboard] == false
      assert config[:dashboard_username] == nil
      assert config[:dashboard_password] == nil
    end

    test "generates a random secret_key_base instead of deriving a guessable one" do
      first = read(:prod)[Unex.Dashboard.Endpoint][:secret_key_base]
      second = read(:prod)[Unex.Dashboard.Endpoint][:secret_key_base]

      assert first != second
      assert byte_size(first) >= 64
    end

    test "uses UNEX_DASHBOARD_SECRET when it is set" do
      System.put_env("UNEX_DASHBOARD_SECRET", String.duplicate("k", 64))

      assert read(:prod)[Unex.Dashboard.Endpoint][:secret_key_base] ==
               String.duplicate("k", 64)
    end
  end

  describe "development" do
    test "boots with nothing set and keeps the documented defaults" do
      config = read(:dev)

      assert config[:dashboard_username] == "admin"
      assert config[:dashboard_password] == "unex"
    end

    test "boots with the dashboard enabled and nothing else set" do
      System.put_env("UNEX_DASHBOARD", "1")

      config = read(:dev)

      assert config[:start_dashboard] == true
      assert config[:dashboard_username] == "admin"
      assert config[:dashboard_password] == "unex"
    end
  end

  describe "test env" do
    test "runtime.exs is inert, so the suite needs nothing set" do
      assert Config.Reader.read!(@runtime_config, env: :test, target: :host) == []
    end

    test "the running test node still has the compiled-in defaults" do
      assert Application.get_env(:unex, :dashboard_username) == "admin"
      assert Application.get_env(:unex, :dashboard_password) == "unex"
    end
  end
end
