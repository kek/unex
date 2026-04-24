import Config

if config_env() != :test do
  # --- Config file loading ---
  config_path =
    System.get_env("UNEX_CONFIG") ||
      Enum.find(
        [Path.expand("~/.config/unex/config.exs"), "/etc/unex/config.exs"],
        &File.exists?/1
      )

  file_config =
    if config_path && File.exists?(config_path) do
      config_path
      |> Config.Reader.read!()
      |> Keyword.get(:unex, [])
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
  data_dir = get.("UNEX_DATA", :data_dir, "./data")
  node_name = get.("UNEX_NODE", :node_name, nil)
  cookie = get.("UNEX_COOKIE", :cookie, nil)

  peers_raw = System.get_env("UNEX_PEERS")

  peers =
    cond do
      peers_raw != nil -> String.split(peers_raw, ",", trim: true) |> Enum.map(&String.trim/1)
      Map.has_key?(file_config, :peers) -> file_config.peers
      true -> []
    end

  encryption_key = get.("UNEX_CONFIG_KEY", :config_encryption_key, nil)

  {encryption_key, key_generated?} =
    if encryption_key do
      {encryption_key, false}
    else
      key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      {key, true}
    end

  api_secret = get.("UNEX_SECRET", :api_secret, nil)

  {api_secret, secret_generated?} =
    if api_secret do
      {api_secret, false}
    else
      secret = Base.encode64(:crypto.strong_rand_bytes(32))
      {secret, true}
    end

  # --- Validation ---
  if node_name && !cookie do
    raise "UNEX_COOKIE is required when UNEX_NODE is set"
  end

  if peers != [] && !node_name do
    raise "UNEX_NODE is required when UNEX_PEERS is set"
  end

  dispatcher_path = System.get_env("UNEX_DISPATCHER") || Map.get(file_config, :dispatcher_path)

  # --- Apply config ---
  config :unex,
    api_port: get_int.("UNEX_PORT", :api_port, 4040),
    mnesia_dir: Path.join(data_dir, "mnesia"),
    blobs_dir: Path.join(data_dir, "blobs"),
    config_encryption_key: encryption_key,
    api_secret: api_secret,
    ucm_path: get.("UCM_PATH", :ucm_path, "ucm"),
    dispatcher_path: dispatcher_path,
    peers: peers,
    node_name: node_name,
    cookie: cookie,
    start_api: true

  # --- Dashboard ---
  dashboard_enabled =
    case System.get_env("UNEX_DASHBOARD") do
      v when v in ["1", "true", "yes"] -> true
      _ -> Map.get(file_config, :start_dashboard, false)
    end

  config :unex,
    start_dashboard: dashboard_enabled,
    dashboard_port: get_int.("UNEX_DASHBOARD_PORT", :dashboard_port, 4041),
    dashboard_username: get.("UNEX_DASHBOARD_USER", :dashboard_username, "admin"),
    dashboard_password: get.("UNEX_DASHBOARD_PASS", :dashboard_password, "unex")

  config :unex, Unex.Dashboard.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: get_int.("UNEX_DASHBOARD_PORT", :dashboard_port, 4041)],
    server: dashboard_enabled,
    secret_key_base:
      System.get_env("UNEX_DASHBOARD_SECRET") ||
        :crypto.hash(:sha256, "unex-dashboard-default-#{node()}") |> Base.encode16()

  if key_generated? do
    IO.puts("[unex] No encryption key configured. Generated: #{encryption_key}")
    IO.puts("[unex] Set UNEX_CONFIG_KEY to persist this key across restarts.")

    IO.puts(
      "[unex] WARNING: If the key changes, existing encrypted Config values become unreadable."
    )
  end

  if secret_generated? do
    IO.puts("[unex] No API secret configured. Generated: #{api_secret}")
    IO.puts("[unex] Set UNEX_SECRET to persist this secret across restarts.")
  end
end
