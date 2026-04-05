defmodule Uniops.ConfigResolver do
  @moduledoc """
  Resolves Uniops configuration from env vars > config file > defaults.
  """

  defstruct [
    :node_name,
    :cookie,
    :config_encryption_key,
    api_port: 4040,
    data_dir: "./data",
    mnesia_dir: nil,
    blobs_dir: nil,
    peers: [],
    ucm_path: "ucm"
  ]

  @type t :: %__MODULE__{}

  @doc "Returns default config values for single-node operation."
  def defaults do
    %__MODULE__{}
  end

  @doc "Reads config from environment variables. Unset vars are nil."
  def resolve_env do
    %{
      node_name: System.get_env("UNIOPS_NODE"),
      cookie: System.get_env("UNIOPS_COOKIE"),
      api_port: parse_int(System.get_env("UNIOPS_PORT")),
      data_dir: System.get_env("UNIOPS_DATA"),
      peers: parse_peers(System.get_env("UNIOPS_PEERS")),
      config_encryption_key: System.get_env("UNIOPS_CONFIG_KEY"),
      ucm_path: System.get_env("UCM_PATH")
    }
  end

  @doc "Merges two configs. Non-nil values in `override` win."
  def merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      if override_val == nil, do: base_val, else: override_val
    end)
  end

  @doc "Validates config. Raises ArgumentError on invalid combinations."
  def validate!(config) do
    if config.node_name && !config.cookie do
      raise ArgumentError, "UNIOPS_COOKIE is required when UNIOPS_NODE is set"
    end

    if config.peers != [] && config.peers != nil && !config.node_name do
      raise ArgumentError, "UNIOPS_NODE is required when UNIOPS_PEERS is set"
    end

    config
  end

  @doc "Derives mnesia_dir and blobs_dir from data_dir."
  def derive_paths(config) do
    %{config |
      mnesia_dir: Path.join(config.data_dir, "mnesia"),
      blobs_dir: Path.join(config.data_dir, "blobs")
    }
  end

  @doc """
  Ensures an encryption key exists. If none is configured, generates a random one.
  Returns `{updated_config, generated?}`.
  """
  def resolve_encryption_key(config) do
    if config.config_encryption_key do
      {config, false}
    else
      key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      {%{config | config_encryption_key: key}, true}
    end
  end

  @doc "Returns :sname for short names, :name for FQDN (contains @)."
  def node_type(name) when is_binary(name) do
    if String.contains?(name, "@"), do: :name, else: :sname
  end

  @doc """
  Full resolution pipeline: defaults -> config file -> env vars -> validate -> derive.
  Returns `{config, key_generated?}`.
  """
  def resolve do
    file_config = load_config_file()

    config =
      defaults()
      |> to_map()
      |> merge(file_config)
      |> merge(resolve_env())
      |> to_struct()
      |> validate!()
      |> derive_paths()

    resolve_encryption_key(config)
  end

  defp load_config_file do
    path = config_file_path()

    if path && File.exists?(path) do
      path
      |> Config.Reader.read!()
      |> Keyword.get(:uniops, [])
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp config_file_path do
    System.get_env("UNIOPS_CONFIG") ||
      find_default_config_file()
  end

  defp find_default_config_file do
    candidates = [
      Path.expand("~/.config/uniops/config.exs"),
      "/etc/uniops/config.exs"
    ]

    Enum.find(candidates, &File.exists?/1)
  end

  defp parse_int(nil), do: nil
  defp parse_int(str), do: String.to_integer(str)

  defp parse_peers(nil), do: nil
  defp parse_peers(""), do: []
  defp parse_peers(str), do: String.split(str, ",", trim: true) |> Enum.map(&String.trim/1)

  defp to_map(%__MODULE__{} = s), do: Map.from_struct(s)
  defp to_map(m) when is_map(m), do: m

  defp to_struct(map) when is_map(map) do
    struct(__MODULE__, map)
  end
end
