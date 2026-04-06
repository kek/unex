import Config

# Compile-time defaults. Runtime config in config/runtime.exs overrides these.
config :unex,
  ucm_path: "ucm",
  ucm_timeout: 30_000,
  workspace_base: Path.join(System.tmp_dir!(), "unex"),
  api_port: 4040,
  start_api: false

import_config "#{config_env()}.exs"
