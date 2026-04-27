import Config

config :unex, code_reloader: true

config :unex, Unex.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  check_origin: false,
  debug_errors: true,
  live_reload: [
    patterns: [
      ~r/lib\/unex\/.*\.ex$/E,
      ~r/lib\/unex_dashboard\/.*\.(ex|heex)$/E
    ]
  ]
