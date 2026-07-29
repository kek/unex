defmodule Unex.Dashboard.CredentialsTest do
  use ExUnit.Case, async: true

  alias Unex.Dashboard.Credentials

  describe "resolve!/2 in :prod with the dashboard enabled" do
    test "refuses to boot when neither variable is set" do
      err =
        assert_raise RuntimeError, fn ->
          Credentials.resolve!(:prod, dashboard_enabled?: true)
        end

      assert err.message =~ "Refusing to boot"
      assert err.message =~ "UNEX_DASHBOARD_USER"
      assert err.message =~ "UNEX_DASHBOARD_PASS"
    end

    test "names only the variable that is missing" do
      err =
        assert_raise RuntimeError, fn ->
          Credentials.resolve!(:prod, username: "ops", dashboard_enabled?: true)
        end

      assert err.message =~ "UNEX_DASHBOARD_PASS is unset"
      refute err.message =~ "UNEX_DASHBOARD_USER is unset"
    end

    test "treats blank values as unset" do
      assert_raise RuntimeError, ~r/Refusing to boot/, fn ->
        Credentials.resolve!(:prod, username: "ops", password: "   ", dashboard_enabled?: true)
      end
    end

    test "refuses the shipped default password even when it is set explicitly" do
      err =
        assert_raise RuntimeError, fn ->
          Credentials.resolve!(:prod,
            username: "admin",
            password: Credentials.default_password(),
            dashboard_enabled?: true
          )
        end

      assert err.message =~ "Refusing to boot"
      assert err.message =~ "UNEX_DASHBOARD_PASS"
    end

    test "refuses other well-known passwords" do
      for weak <- Credentials.known_insecure_passwords() do
        assert_raise RuntimeError, ~r/Refusing to boot/, fn ->
          Credentials.resolve!(:prod,
            username: "ops",
            password: weak,
            dashboard_enabled?: true
          )
        end
      end
    end

    test "accepts properly set credentials" do
      assert {"ops", "j5Yk-h5vQz-not-a-default"} ==
               Credentials.resolve!(:prod,
                 username: "ops",
                 password: "j5Yk-h5vQz-not-a-default",
                 dashboard_enabled?: true
               )
    end
  end

  describe "resolve!/2 in :prod with the dashboard disabled" do
    test "leaves no credentials behind rather than the dev defaults" do
      assert {nil, nil} == Credentials.resolve!(:prod, dashboard_enabled?: false)
    end

    test "defaults to disabled when the caller says nothing" do
      assert {nil, nil} == Credentials.resolve!(:prod, [])
    end
  end

  describe "resolve!/2 in :dev and :test" do
    test "falls back to the documented defaults with nothing configured" do
      for env <- [:dev, :test] do
        assert {Credentials.default_username(), Credentials.default_password()} ==
                 Credentials.resolve!(env, [])
      end
    end

    test "falls back even when the dashboard is enabled" do
      assert {"admin", "unex"} == Credentials.resolve!(:dev, dashboard_enabled?: true)
    end

    test "configured values still win" do
      assert {"ops", "hunter2"} ==
               Credentials.resolve!(:dev, username: "ops", password: "hunter2")
    end

    test "blank values fall back to the defaults" do
      assert {"admin", "unex"} == Credentials.resolve!(:dev, username: "", password: "  ")
    end
  end

  describe "resolve_secret_key_base/1" do
    test "uses a configured value as-is" do
      assert {"a-configured-secret", false} ==
               Credentials.resolve_secret_key_base("a-configured-secret")
    end

    test "generates a random value when nothing is configured" do
      {first, generated?} = Credentials.resolve_secret_key_base(nil)
      {second, true} = Credentials.resolve_secret_key_base("")

      assert generated?
      assert first != second
      assert byte_size(first) >= 64
    end
  end
end
