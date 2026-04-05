import Config

if config_env() != :test do
  # --- Config file loading ---
  config_path =
    System.get_env("UNIOPS_CONFIG") ||
      Enum.find(
        [Path.expand("~/.config/uniops/config.exs"), "/etc/uniops/config.exs"],
        &File.exists?/1
      )

  file_config =
    if config_path && File.exists?(config_path) do
      config_path
      |> Config.Reader.read!()
      |> Keyword.get(:uniops, [])
      |> Map.new()
    else
      %{}
    end

  # --- Helpers ---
  get = fn env_var, file_key, default ->
    case System.get_env(env_var) do
      nil -> Map.get(file_config, file_key, default)
      val -> val
    end
  end

  get_int = fn env_var, file_key, default ->
    case System.get_env(env_var) do
      nil -> Map.get(file_config, file_key, default)
      val -> String.to_integer(val)
    end
  end

  # --- Resolve values ---
  data_dir = get.("UNIOPS_DATA", :data_dir, "./data")
  node_name = get.("UNIOPS_NODE", :node_name, nil)
  cookie = get.("UNIOPS_COOKIE", :cookie, nil)

  peers_raw = System.get_env("UNIOPS_PEERS")
  peers =
    cond do
      peers_raw != nil -> String.split(peers_raw, ",", trim: true) |> Enum.map(&String.trim/1)
      Map.has_key?(file_config, :peers) -> file_config.peers
      true -> []
    end

  encryption_key = get.("UNIOPS_CONFIG_KEY", :config_encryption_key, nil)

  {encryption_key, key_generated?} =
    if encryption_key do
      {encryption_key, false}
    else
      key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      {key, true}
    end

  # --- Validation ---
  if node_name && !cookie do
    raise "UNIOPS_COOKIE is required when UNIOPS_NODE is set"
  end

  if peers != [] && !node_name do
    raise "UNIOPS_NODE is required when UNIOPS_PEERS is set"
  end

  # --- Apply config ---
  config :uniops,
    api_port: get_int.("UNIOPS_PORT", :api_port, 4040),
    mnesia_dir: Path.join(data_dir, "mnesia"),
    blobs_dir: Path.join(data_dir, "blobs"),
    config_encryption_key: encryption_key,
    ucm_path: get.("UCM_PATH", :ucm_path, "ucm"),
    peers: peers,
    node_name: node_name,
    cookie: cookie,
    start_api: true

  if key_generated? do
    IO.puts("[uniops] No encryption key configured. Generated: #{encryption_key}")
    IO.puts("[uniops] Set UNIOPS_CONFIG_KEY to persist this key across restarts.")
    IO.puts("[uniops] WARNING: If the key changes, existing encrypted Config values become unreadable.")
  end
end
