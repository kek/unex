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

config :esbuild,
  version: "0.21.5",
  unex_dashboard: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  unex_dashboard: [
    args:
      ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
