# Unex HTTP API Reference

All endpoints except `/health` require a bearer token:

```bash
AUTH="Authorization: Bearer YOUR_SECRET"
```

The secret is printed at startup. Set `UNEX_SECRET` to persist it across restarts.

## Storage

### Databases

```bash
# Create a database (a namespace for tables and cells)
curl -s -X POST localhost:4040/databases \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"name":"mydb"}'
```

### Tables (ordered key-value)

```bash
# Create a table
curl -s -X POST localhost:4040/databases/mydb/tables/users \
  -H "$AUTH"

# Write
curl -s -X POST localhost:4040/databases/mydb/tables/users/write \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"key":"alice","value":"{\"age\":30,\"role\":\"admin\"}"}'

# Read
curl -s -H "$AUTH" localhost:4040/databases/mydb/tables/users/read/alice

# Range scan (sorted, inclusive)
curl -s -X POST localhost:4040/databases/mydb/tables/users/scan \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"from":"a","to":"z"}'

# Delete
curl -s -X DELETE localhost:4040/databases/mydb/tables/users/alice \
  -H "$AUTH"
```

### Cells (single named values)

```bash
# Write
curl -s -X POST localhost:4040/databases/mydb/cells/counter/write \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"value":"42"}'

# Read
curl -s -H "$AUTH" localhost:4040/databases/mydb/cells/counter/read
```

### Transactions

```bash
# Atomic all-or-nothing batch
curl -s -X POST localhost:4040/databases/mydb/tx \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"operations":[
    {"op":"write_table","table":"users","key":"bob","value":"{}"},
    {"op":"write_cell","name":"last_updated","value":"2026-04-05"}
  ]}'
```

## Config (encrypted secrets)

Values are AES-256-GCM encrypted at rest, scoped by environment name.

```bash
# Store a secret
curl -s -X POST localhost:4040/config/prod/api_key \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"value":"sk-secret-123"}'

# Read
curl -s -H "$AUTH" localhost:4040/config/prod/api_key

# List keys for an environment
curl -s -H "$AUTH" localhost:4040/config/prod

# Delete
curl -s -X DELETE localhost:4040/config/prod/api_key \
  -H "$AUTH"
```

## Blobs (binary object storage)

```bash
# Write (value is base64-encoded)
curl -s -X POST localhost:4040/blobs/mydb/images/photo.jpg \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"data\":\"$(base64 < /path/to/photo.jpg)\"}"

# Read
curl -s -H "$AUTH" localhost:4040/blobs/mydb/images/photo.jpg

# List by prefix
curl -s -X POST localhost:4040/blobs/mydb/list \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"prefix":"images/"}'

# Delete
curl -s -X DELETE localhost:4040/blobs/mydb/images/photo.jpg \
  -H "$AUTH"
```

## Scratch (ephemeral cache)

Node-local ETS cache. Data is lost on server restart.

```bash
# Write
curl -s -X POST localhost:4040/scratch/session:abc \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"value":"user-data"}'

# Read
curl -s -H "$AUTH" localhost:4040/scratch/session:abc

# Delete
curl -s -X DELETE localhost:4040/scratch/session:abc \
  -H "$AUTH"
```

## Log

ETS ring buffer (last 1000 entries), also forwarded to Elixir's Logger.

```bash
# Append
curl -s -X POST localhost:4040/log \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"level":"info","message":"server started","metadata":{"port":4040}}'

# Read recent N entries
curl -s -H "$AUTH" localhost:4040/log/recent/20
```

## Bytecode

Push and pull deployment bundles by content hash. Used by the deploy system.

```bash
# Push a bundle (hex-encoded in JSON, server computes SHA256 hash)
curl -s -X POST localhost:4040/bytecode \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"data":"<hex-encoded-bundle-bytes>"}'
# Returns: {"hash":"<sha256>"}

# Pull a bundle by hash
curl -s -H "$AUTH" localhost:4040/bytecode/<hash> --output bundle.bin
```

You typically don't interact with this endpoint directly — the deploy system uses it internally.

## Services

```bash
# Deploy: pull from Share, compile, register
curl -s -X POST localhost:4040/services/my-service/deploy \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"entry":"mainService","project":"@myorg/myapp"}'

# Release: update the stable name pointer to a new hash
curl -s -X POST localhost:4040/services/my-service/release \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"hash":"def456ghi"}'

# Call a service (JSON response)
curl -s -X POST localhost:4040/services/my-service/call \
  -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '"{}"'

# Web: serve stdout as HTML (no auth required, browser-friendly)
curl localhost:4040/services/my-service/web

# List deployed services
curl -s -H "$AUTH" localhost:4040/services

# Undeploy
curl -s -X DELETE localhost:4040/services/my-service \
  -H "$AUTH"
```
