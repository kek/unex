defmodule Unex.ConfigResolverTest do
  use ExUnit.Case, async: true

  alias Unex.ConfigResolver

  describe "defaults/0" do
    test "returns sensible single-node defaults" do
      defaults = ConfigResolver.defaults()
      assert defaults.api_port == 4040
      assert defaults.data_dir == "./data"
      assert defaults.node_name == nil
      assert defaults.cookie == nil
      assert defaults.peers == []
      assert defaults.api_secret == nil
      assert defaults.config_encryption_key == nil
      assert defaults.ucm_path == "ucm"
    end
  end

  describe "resolve_env/0" do
    test "reads UNEX_PORT" do
      System.put_env("UNEX_PORT", "5050")
      on_exit(fn -> System.delete_env("UNEX_PORT") end)

      env = ConfigResolver.resolve_env()
      assert env.api_port == 5050
    end

    test "reads UNEX_NODE" do
      System.put_env("UNEX_NODE", "mynode")
      on_exit(fn -> System.delete_env("UNEX_NODE") end)

      env = ConfigResolver.resolve_env()
      assert env.node_name == "mynode"
    end

    test "reads UNEX_PEERS as comma-separated list" do
      System.put_env("UNEX_PEERS", "b@host1,c@host2")
      on_exit(fn -> System.delete_env("UNEX_PEERS") end)

      env = ConfigResolver.resolve_env()
      assert env.peers == ["b@host1", "c@host2"]
    end

    test "reads UNEX_SECRET" do
      System.put_env("UNEX_SECRET", "top-secret")
      on_exit(fn -> System.delete_env("UNEX_SECRET") end)

      env = ConfigResolver.resolve_env()
      assert env.api_secret == "top-secret"
    end

    test "ignores unset env vars" do
      env = ConfigResolver.resolve_env()
      assert env.node_name == nil
      assert env.peers == nil
    end
  end

  describe "merge/2" do
    test "env overrides defaults" do
      defaults = %{api_port: 4040, node_name: nil}
      env = %{api_port: 5050, node_name: nil}
      merged = ConfigResolver.merge(defaults, env)
      assert merged.api_port == 5050
    end

    test "nil env values do not override" do
      defaults = %{api_port: 4040, node_name: nil}
      env = %{api_port: nil, node_name: "a"}
      merged = ConfigResolver.merge(defaults, env)
      assert merged.api_port == 4040
      assert merged.node_name == "a"
    end
  end

  describe "validate!/1" do
    test "passes with valid single-node config" do
      config = ConfigResolver.defaults()
      assert ConfigResolver.validate!(config) == config
    end

    test "raises when UNEX_NODE set without UNEX_COOKIE" do
      config = %{ConfigResolver.defaults() | node_name: "a", cookie: nil}

      assert_raise ArgumentError, ~r/UNEX_COOKIE is required/, fn ->
        ConfigResolver.validate!(config)
      end
    end

    test "raises when UNEX_PEERS set without UNEX_NODE" do
      config = %{ConfigResolver.defaults() | peers: ["b@host"], node_name: nil}

      assert_raise ArgumentError, ~r/UNEX_NODE is required/, fn ->
        ConfigResolver.validate!(config)
      end
    end

    test "passes with node + cookie + peers" do
      config = %{ConfigResolver.defaults() | node_name: "a", cookie: "secret", peers: ["b@host"]}
      assert ConfigResolver.validate!(config) == config
    end
  end

  describe "derive_paths/1" do
    test "derives mnesia_dir and blobs_dir from data_dir" do
      config = %{ConfigResolver.defaults() | data_dir: "/var/data/unex"}
      derived = ConfigResolver.derive_paths(config)
      assert derived.mnesia_dir == "/var/data/unex/mnesia"
      assert derived.blobs_dir == "/var/data/unex/blobs"
    end
  end

  describe "resolve_encryption_key/1" do
    test "returns config as-is when key is set" do
      config = %{ConfigResolver.defaults() | config_encryption_key: "my-secret"}
      {resolved, generated?} = ConfigResolver.resolve_encryption_key(config)
      assert resolved.config_encryption_key == "my-secret"
      refute generated?
    end

    test "generates a random key when none is set" do
      config = ConfigResolver.defaults()
      {resolved, generated?} = ConfigResolver.resolve_encryption_key(config)
      assert is_binary(resolved.config_encryption_key)
      assert byte_size(resolved.config_encryption_key) > 0
      assert generated?
    end
  end

  describe "resolve/0" do
    test "derives startup paths and generates missing secrets" do
      original_env =
        for key <- ["UNEX_DATA", "UNEX_SECRET", "UNEX_CONFIG_KEY"], into: %{} do
          {key, System.get_env(key)}
        end

      System.put_env("UNEX_DATA", "/tmp/unex-resolve")
      System.delete_env("UNEX_SECRET")
      System.delete_env("UNEX_CONFIG_KEY")

      on_exit(fn ->
        Enum.each(original_env, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)

      {resolved, key_generated?, secret_generated?} = ConfigResolver.resolve()

      assert resolved.mnesia_dir == "/tmp/unex-resolve/mnesia"
      assert resolved.blobs_dir == "/tmp/unex-resolve/blobs"
      assert is_binary(resolved.config_encryption_key)
      assert is_binary(resolved.api_secret)
      assert key_generated?
      assert secret_generated?
    end
  end

  describe "node_type/1" do
    test "returns :sname for short name" do
      assert ConfigResolver.node_type("a") == :sname
    end

    test "returns :name for FQDN" do
      assert ConfigResolver.node_type("a@10.0.1.5") == :name
    end
  end
end
