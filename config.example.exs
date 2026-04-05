# Uniops configuration file example.
#
# Copy this file and point to it:
#   UNIOPS_CONFIG=/path/to/config.exs mix uniops.start
#
# Or place it at one of the default locations:
#   ~/.config/uniops/config.exs
#   /etc/uniops/config.exs
#
# Environment variables always override values from this file.

import Config

config :uniops,
  # Node identity (required for clustering)
  # node_name: "a",                              # short name (same subnet) — or "a@10.0.1.5" for cross-network
  # cookie: "uniops_secret",                     # must match on all cluster nodes

  # HTTP API
  api_port: 4040,

  # Data storage
  data_dir: "./data",                             # Mnesia and blobs stored under this directory

  # Cluster peers (auto-connect on startup)
  # peers: ["b@10.0.1.2", "c@10.0.1.3"],

  # Config encryption key (AES-256-GCM, base64-encoded)
  # If not set, a random key is generated at startup (printed to stdout).
  # WARNING: changing this key makes existing encrypted Config values unreadable.
  # config_encryption_key: "base64-encoded-32-byte-key",

  # UCM binary path
  ucm_path: "ucm"
