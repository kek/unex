import Config

config :unex, Unex.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:unex_dashboard, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:unex_dashboard, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/unex_dashboard/(?:live|components)/.*(ex|heex)$"
    ]
  ]
