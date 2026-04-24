import Config

config :unex, Unex.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  check_origin: false,
  debug_errors: true
