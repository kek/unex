import Config

# Don't auto-start the API server or Mnesia in tests — tests manage their own instances
config :uniops,
  start_api: false,
  mnesia_dir: nil
