# Dispatcher Pool Design

**Date:** 2026-06-07
**Status:** Approved

## Motivation

The current `Unex.Dispatcher` is a single GenServer wrapping one persistent UCM
subprocess over a localhost TCP socket. Every `Services.call` queues on that one
GenServer, so a slow service call stalls every other caller (head-of-line
blocking). The goal is to replace this with a fixed pool of N independent
dispatchers so that:

- Burst concurrency is absorbed without head-of-line blocking.
- Sustained throughput scales with pool size.
- Slow callers do not stall unrelated fast callers.

The pool size is fixed at boot (pre-started workers, no cold-start latency) but
the design intentionally leaves room for future dynamic sizing.

## Architecture

`Unex.Dispatcher` remains **unchanged** — it is still a valid standalone
GenServer. A new module, `Unex.Dispatcher.Pool`, sits in front of N Dispatcher
workers and implements the `NimblePool.Worker` behaviour.

```
Services.eval_local(hash, timeout)
  └─ Dispatcher.Pool.eval(bytes, timeout)
       └─ NimblePool.checkout!(__MODULE__, :checkout, fn _, pid -> ... end, timeout)
            ├─ [blocks until a free worker is available, up to timeout]
            ├─ handle_checkout: verifies Dispatcher.running?(pid), returns pid
            ├─ Dispatcher.eval(pid, bytes, timeout)
            └─ handle_checkin: returns pid to pool
```

NimblePool manages the worker lifecycle, waiter queue, timeout, and crash
recovery. No external dep beyond `nimble_pool` itself (zero transitive deps).

## Components

### `Unex.Dispatcher.Pool` (new file: `lib/unex/dispatcher/pool.ex`)

Implements `NimblePool.Worker` and exposes two public functions:

**`eval(bytes, timeout)`** — checks out a free worker, calls
`Dispatcher.eval(pid, bytes, timeout)`, checks the worker back in, returns the
result. When all workers are busy and `timeout` elapses, returns
`{:error, :pool_timeout}` (NimblePool.Timeout is caught and normalized).

**`available?/0`** — returns `true` if the pool process is alive and has at
least one healthy worker. Replaces `Dispatcher.running?/0` in `Services`.

NimblePool callbacks:

| Callback | Behaviour |
|---|---|
| `init_worker/1` | Calls `Dispatcher.start_link([name: nil])` (unnamed so N workers coexist); returns `{:ok, pid, pool_state}` |
| `handle_checkout/4` | Checks `Dispatcher.running?(pid)`; returns `{:ok, pid, pool_state}` or `{:remove, :not_running, pool_state}` (triggers worker replacement) |
| `handle_checkin/4` | Always returns `{:ok, pool_state}` — dispatchers are stateless between calls |
| `terminate_worker/3` | Calls `GenServer.stop(pid)` — existing Dispatcher.terminate/2 closes sockets and kills the ucm port |

### `Unex.Application` (modified)

`cluster_children/0` replaces the bare `Unex.Dispatcher` child with
`{Unex.Dispatcher.Pool, pool_size: pool_size()}` where `pool_size/0` reads
`:dispatcher_pool_size` from application config.

### `Unex.Services` (modified)

`eval_local/2` changes two call sites:
- `Dispatcher.running?()` → `Dispatcher.Pool.available?()`
- `Dispatcher.eval(Unex.Dispatcher, data, timeout)` → `Dispatcher.Pool.eval(data, timeout)`

### `mix.exs` (modified)

Add `{:nimble_pool, "~> 1.1"}` to `deps/0`.

### Config (modified)

`config/config.exs`: add `dispatcher_pool_size: 4` to the `:unex` config block.

`config/runtime.exs`: add `UNEX_DISPATCHER_POOL_SIZE` env var resolution using
the existing `get_int` helper, applied to the `:dispatcher_pool_size` key.

## Configuration

| Env var | Config key | Default | Description |
|---|---|---|---|
| `UNEX_DISPATCHER_POOL_SIZE` | `:dispatcher_pool_size` | `4` | Number of persistent UCM subprocesses in the pool |

The default of 4 provides headroom for concurrent bursts without wasting
significant resources. Each worker holds one UCM subprocess and one TCP socket.

## Error Handling

| Condition | Result |
|---|---|
| All workers busy, timeout exceeded | `{:error, :pool_timeout}` |
| Worker crashes mid-call | Worker removed from pool, replacement started; caller receives `{:error, reason}` from the crashed Dispatcher |
| UCM not running / `.uc` missing | Pool does not start (same `:ignore` logic as before); `available?/0` returns `false` |
| UCM eval error | `{:error, reason}` — unchanged from current behaviour |

## Testing

**Integration test** (`test/integration/service_lifecycle_test.exs`):
- Start `Dispatcher.Pool` instead of a single `Dispatcher`.
- Update the UCM subprocess count assertion from `== 1` to `== pool_size`.
- The pool size in the test is set to 1 (via application config override before
  the pool starts) so existing assertions about single-subprocess behaviour
  remain valid; a separate assertion verifies the pool accepts concurrent calls
  without queuing when size > 1.

**Unit test** (future — not in this plan): concurrent callers on a pool of size
2 complete without head-of-line blocking. Not implemented here because it
requires a real `dispatcher.uc` binary and belongs in the integration suite.

## Future Considerations

- **Dynamic sizing**: `NimblePool` supports lazy worker init. To allow dynamic
  sizing, pass `lazy: true` and a `pool_size` config that can change at runtime.
  The `Pool.eval/2` API is unchanged.
- **Per-service pools**: if different services have different SLAs, multiple
  named pool instances could be started. The current design supports this — Pool
  is not a singleton beyond its registered name.
- **Overflow / rejection**: the current design queues all callers. A hard reject
  could be added by wrapping `NimblePool.checkout!` with a queue-depth check
  before checkout.

## Open Questions

None — all design decisions were resolved in the brainstorming session.
