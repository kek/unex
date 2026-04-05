defmodule Uniops.Abilities.ConfigTest do
  use ExUnit.Case, async: false

  alias Uniops.Abilities.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    :ok
  end

  describe "set/3 and get/2" do
    test "stores and retrieves a secret" do
      assert :ok = Config.set("prod", "api_key", "sk-secret-123")
      assert {:ok, "sk-secret-123"} = Config.get("prod", "api_key")
    end

    test "returns :not_found for missing key" do
      assert :not_found = Config.get("prod", "missing")
    end

    test "different environments are isolated" do
      Config.set("prod", "key", "prod-value")
      Config.set("staging", "key", "staging-value")
      assert {:ok, "prod-value"} = Config.get("prod", "key")
      assert {:ok, "staging-value"} = Config.get("staging", "key")
    end

    test "values are encrypted at rest" do
      Config.set("prod", "secret", "plaintext-value")
      # Read raw from Mnesia — value should NOT be plaintext
      {:atomic, [{_, _, raw}]} =
        :mnesia.transaction(fn ->
          :mnesia.read(Config.table_name(), {"prod", "secret"})
        end)
      refute raw == "plaintext-value"
      assert is_binary(raw)
    end

    test "overwrites existing key" do
      Config.set("prod", "key", "v1")
      Config.set("prod", "key", "v2")
      assert {:ok, "v2"} = Config.get("prod", "key")
    end
  end

  describe "delete/2" do
    test "removes a secret" do
      Config.set("prod", "temp", "val")
      assert :ok = Config.delete("prod", "temp")
      assert :not_found = Config.get("prod", "temp")
    end
  end

  describe "list/1" do
    test "returns keys for an environment" do
      Config.set("prod", "a", "1")
      Config.set("prod", "b", "2")
      Config.set("staging", "c", "3")
      keys = Config.list("prod")
      assert "a" in keys
      assert "b" in keys
      refute "c" in keys
    end
  end
end
