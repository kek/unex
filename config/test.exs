import Config

# Tests manage their own Mnesia and API instances — don't auto-start anything
config :unex,
  start_api: false,
  start_dispatcher: false,
  mnesia_dir: nil,
  blobs_dir: nil,
  hash_cache_dir: nil,
  config_encryption_key: "test-key-not-for-production",
  api_secret: "test-secret"

config :unex, start_dashboard: false

config :unex, Unex.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4042],
  secret_key_base: String.duplicate("a", 64),
  server: false
