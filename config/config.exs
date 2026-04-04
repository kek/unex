import Config

config :uniops,
  ucm_path: System.get_env("UCM_PATH") || "ucm",
  ucm_timeout: String.to_integer(System.get_env("UCM_TIMEOUT") || "30000"),
  workspace_base: System.get_env("UNIOPS_WORKSPACE") || Path.join(System.tmp_dir!(), "uniops")
