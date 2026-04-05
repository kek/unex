import Config

# Compile-time defaults. Runtime config in config/runtime.exs overrides these.
config :uniops,
  ucm_path: "ucm",
  ucm_timeout: 30_000,
  workspace_base: Path.join(System.tmp_dir!(), "uniops"),
  api_port: 4040,
  start_api: false

import_config "#{config_env()}.exs"
