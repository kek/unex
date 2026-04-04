import Config

config :uniops,
  ucm_path: System.get_env("UCM_PATH") || "ucm",
  ucm_timeout: String.to_integer(System.get_env("UCM_TIMEOUT") || "30000"),
  workspace_base: System.get_env("UNIOPS_WORKSPACE") || Path.join(System.tmp_dir!(), "uniops"),
  api_port: String.to_integer(System.get_env("UNIOPS_API_PORT") || "4040"),
  mnesia_dir: System.get_env("UNIOPS_MNESIA_DIR") || Path.join(System.tmp_dir!(), "uniops_data"),
  start_api: true

import_config "#{config_env()}.exs"
