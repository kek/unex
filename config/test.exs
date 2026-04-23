import Config

# Tests manage their own Mnesia and API instances — don't auto-start anything
config :unex,
  start_api: false,
  start_dispatcher: false,
  mnesia_dir: nil,
  blobs_dir: nil,
  config_encryption_key: "test-key-not-for-production",
  api_secret: "test-secret"
