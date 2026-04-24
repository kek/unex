import Config

# Compile-time defaults. Runtime config in config/runtime.exs overrides these.
config :unex,
  ucm_path: "ucm",
  ucm_timeout: 30_000,
  workspace_base: Path.join(System.tmp_dir!(), "unex"),
  api_port: 4040,
  start_api: false,
  start_dashboard: false,
  dashboard_port: 4041,
  dashboard_username: "admin",
  dashboard_password: "unex"

import_config "#{config_env()}.exs"
