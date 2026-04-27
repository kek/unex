defmodule Unex.Cluster.HashCache do
  @moduledoc """
  ETS-backed cache for Unison bytecode blobs, keyed by SHA256 hex string.

  Reads go directly to ETS (no GenServer round-trip); writes go through
  the GenServer so that only one process owns the table.

  When started with a `:dir` option, every put is mirrored to a file at
  `<dir>/<hash>` so the cache survives restarts. On init, the cache
  re-hydrates from any pre-existing files in `dir`. The on-disk layout
  is content-addressed: filename equals the hash (lowercase hex).
  """

  use GenServer

  @type hash :: String.t()

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the cache. Options:
    * `:name` — registered process name (default `#{__MODULE__}`)
    * `:dir` — when set, blobs are persisted to this directory and the
      cache is hydrated from it on init (default `nil` = pure ETS)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Two-argument form: computes SHA256 of `data`, stores it, returns the hex
  hash string. `server` defaults to `#{__MODULE__}`.
  """
  def put(server \\ __MODULE__, data) when is_binary(data) do
    hash = hash_of(data)
    :ok = GenServer.call(server, {:put, hash, data})
    hash
  end

  @doc """
  Three-argument form: stores `data` under the given explicit `hash`.
  Returns `:ok`. Always requires an explicit `server` argument.
  """
  def put(server, hash, data) when is_binary(hash) and is_binary(data) do
    GenServer.call(server, {:put, hash, data})
  end

  @doc "Returns `{:ok, data}` or `:not_found`. Reads directly from ETS."
  def get(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, hash) do
      [{^hash, data}] -> {:ok, data}
      [] -> :not_found
    end
  end

  @doc "Returns `true` if `hash` is in the cache."
  def has?(server \\ __MODULE__, hash) do
    table = GenServer.call(server, :table)
    :ets.member(table, hash)
  end

  @doc "Returns the list of all hash strings stored in the cache."
  def list(server \\ __MODULE__) do
    table = GenServer.call(server, :table)
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc """
  Returns `[{hash, size_bytes}, ...]` for every blob in the cache.
  One ETS traversal.
  """
  def list_with_sizes(server \\ __MODULE__) do
    table = GenServer.call(server, :table)

    :ets.foldl(
      fn {hash, data}, acc -> [{hash, byte_size(data)} | acc] end,
      [],
      table
    )
  end

  @doc """
  Returns `[{hash, size_bytes, inserted_at_ms}, ...]` for every blob.
  `inserted_at_ms` is the `System.system_time(:millisecond)` captured on
  the most recent put for that hash (0 if meta missing, which shouldn't
  happen under normal operation).
  """
  def list_with_meta(server \\ __MODULE__) do
    table = GenServer.call(server, :table)
    meta = GenServer.call(server, :meta)

    :ets.foldl(
      fn {hash, data}, acc ->
        ts =
          case :ets.lookup(meta, hash) do
            [{^hash, t}] -> t
            [] -> 0
          end

        [{hash, byte_size(data), ts} | acc]
      end,
      [],
      table
    )
  end

  @doc "Returns the insertion timestamp (ms) for `hash`, or `nil`."
  def inserted_at(server \\ __MODULE__, hash) do
    meta = GenServer.call(server, :meta)

    case :ets.lookup(meta, hash) do
      [{^hash, t}] -> t
      [] -> nil
    end
  end

  @doc """
  Returns a map with `:count` and `:total_bytes` — cheap aggregate stats
  for monitoring/dashboards. Walks the ETS table once.
  """
  def stats(server \\ __MODULE__) do
    table = GenServer.call(server, :table)

    :ets.foldl(
      fn {_hash, data}, acc ->
        %{count: acc.count + 1, total_bytes: acc.total_bytes + byte_size(data)}
      end,
      %{count: 0, total_bytes: 0},
      table
    )
  end

  @doc "Computes the SHA256 hex string for `data` (lowercase)."
  def hash_of(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    dir = Keyword.get(opts, :dir)
    table = :ets.new(name, [:set, :public, {:read_concurrency, true}])
    meta = :ets.new(:"#{name}_meta", [:set, :public, {:read_concurrency, true}])

    if dir do
      File.mkdir_p!(dir)
      hydrate_from_dir(table, meta, dir)
    end

    {:ok, %{table: table, meta: meta, dir: dir}}
  end

  @impl true
  def handle_call({:put, hash, data}, _from, state) do
    :ets.insert(state.table, {hash, data})
    ts = System.system_time(:millisecond)
    :ets.insert(state.meta, {hash, ts})
    if state.dir, do: write_blob(state.dir, hash, data)
    Unex.Dashboard.Events.broadcast_hashcache({:put, hash, byte_size(data)})
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, state), do: {:reply, state.table, state}
  def handle_call(:meta, _from, state), do: {:reply, state.meta, state}

  # ---------------------------------------------------------------------------
  # Persistence helpers
  # ---------------------------------------------------------------------------

  defp blob_path(dir, hash), do: Path.join(dir, hash)

  defp write_blob(dir, hash, data) do
    path = blob_path(dir, hash)
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
    :ok
  end

  defp hydrate_from_dir(table, meta, dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn name ->
          path = Path.join(dir, name)

          if valid_hash?(name) and File.regular?(path) do
            with {:ok, data} <- File.read(path) do
              :ets.insert(table, {name, data})
              ts = mtime_ms(path)
              :ets.insert(meta, {name, ts})
            end
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  # HashCache stores two key formats:
  #   * SHA256 hex (64 chars) — used for root Value bytes
  #   * Unison Link.Term hash (~52 lowercase base32 chars) — used for Code blobs
  # Both are lowercase alphanumeric. The length window covers both and filters
  # stray files (READMEs, `.tmp` partials from interrupted writes, etc).
  defp valid_hash?(name) do
    String.match?(name, ~r/^[0-9a-z]{40,80}$/)
  end

  defp mtime_ms(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: secs}} -> secs * 1000
      _ -> 0
    end
  end
end
