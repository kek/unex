import Config

# Compile-time defaults. Runtime config in config/runtime.exs overrides these.
config :unex,
  ucm_path: "ucm",
  ucm_timeout: 30_000,
  workspace_base: Path.join(System.tmp_dir!(), "unex"),
  api_port: 4040,
  start_api: false,
  start_dashboard: false,
  dispatcher_pool_size: 4,
  dashboard_port: 4041,
  dashboard_username: "admin",
  dashboard_password: "unex",
  dashboard_children: [Unex.Dashboard.Telemetry, Unex.Dashboard.Endpoint]

config :unex, Unex.Dashboard.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Unex.Dashboard.ErrorHTML],
    layout: false
  ],
  pubsub_server: Unex.PubSub,
  live_view: [signing_salt: "unex-dashboard-salt"],
  secret_key_base: String.duplicate("a", 64)

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
