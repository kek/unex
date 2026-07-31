defmodule Unex.Services do
  @moduledoc """
  Public API for deploying, calling, listing, and undeploying named services.

  A service is a Unison thunk registered under a human-readable name. Deploys
  pull the project, extract a serialized `Value` for the entry point plus all
  transitively reachable `Code` bytes, and store them in the cluster's shared
  `HashCache`. Calls dispatch the root `Value` through a pool of long-lived
  `Unex.Dispatcher` processes via `Unex.Dispatcher.Pool` which evaluates it and fetches missing `Code`
  on demand via `GET /code/:termhash`.
  """

  alias Unex.Services.Registry
  alias Unex.Services.Registry.Entry
  alias Unex.Cluster.{HashCache, SyncServer}
  alias Unex.Runner.Result

  @doc """
  Calls a named service. Returns `{:ok, %Runner.Result{}}` or
  `{:error, reason}`. The `Result` shape is preserved for API/controller
  compatibility — `stdout` holds the Unison program's returned `Text`.
  """
  def call(name, opts \\ []) do
    Unex.Dashboard.Events.broadcast_services({:call_started, name, node()})

    try do
      case Registry.resolve(name) do
        {:ok, %Entry{} = entry} -> execute(entry, opts)
        :not_found -> {:error, :not_found}
      end
    after
      Unex.Dashboard.Events.broadcast_services({:call_finished, name, node()})
    end
  end

  defp execute(%Entry{hash: hash}, opts) do
    target = Keyword.get(opts, :node, node())
    timeout = Keyword.get(opts, :timeout, 60_000)

    if target == node() do
      eval_local(hash, timeout)
    else
      case :rpc.call(target, __MODULE__, :eval_local, [hash, timeout], timeout + 5_000) do
        {:badrpc, reason} -> {:error, {:rpc_failed, target, reason}}
        result -> result
      end
    end
  end

  @doc """
  Resolves the root `Value` bytes for a service hash and hands them to the
  local `Unex.Dispatcher.Pool` for evaluation. Public because it is called via
  RPC from remote nodes.
  """
  def eval_local(hash, timeout) do
    cond do
      not Unex.Dispatcher.Pool.available?() ->
        {:error, :dispatcher_not_started}

      true ->
        with {:ok, resolved} <- SyncServer.resolve([hash]),
             data when is_binary(data) <- Map.get(resolved, hash) do
          case Unex.Dispatcher.Pool.eval(data, timeout) do
            {:ok, text} -> {:ok, %Result{stdout: text, stderr: "", exit_code: 0}}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, _} = err -> err
          nil -> {:error, {:missing, hash}}
        end
    end
  end

  @doc """
  Points a service name at an existing root-value hash.

  Deploys push the root `Value` bytes and `Code` bytes into `HashCache` first,
  then `release` moves the name pointer to any existing hash.
  """
  def release(name, hash, opts \\ []) do
    Registry.register(
      Registry,
      name,
      normalize_hash(hash),
      node(),
      merge_with_existing(name, opts)
    )
  end

  # If the caller didn't provide project/entry_point, preserve whatever the
  # previous registration had. This keeps Share links alive across a bare
  # `release` that follows a project-aware `deploy`.
  #
  # "Didn't provide" means the key is absent, not that its value is nil: a file
  # deploy passes `project: nil` deliberately, and inheriting a stale Share
  # project there would make the dashboard link a local build to somebody's
  # Share page.
  defp merge_with_existing(name, opts) do
    needs_merge? =
      not Keyword.has_key?(opts, :project) or not Keyword.has_key?(opts, :entry_point)

    if needs_merge? do
      case Registry.lookup(name) do
        {:ok, existing} ->
          opts
          |> Keyword.put_new(:project, existing.project)
          |> Keyword.put_new(:entry_point, existing.entry_point)

        :not_found ->
          opts
      end
    else
      opts
    end
  end

  defp normalize_hash("#" <> rest), do: rest
  defp normalize_hash(hash), do: hash

  @doc "Lists all registered services."
  def list, do: Registry.list()

  @doc "Unregisters a named service."
  def undeploy(name), do: Registry.unregister(name)

  @doc """
  Deploys a service by ingesting its source into the runtime codebase,
  extracting the entry point's serialized `Value`, and storing all
  transitively reachable `Code` bytes. Returns `{:ok, %Entry{}}` on success.

  `source` is a `t:Unex.Runtime.source/0`:

    * `{:share, project}` — pull from Unison Share, what a production deploy
      does. A bare binary means this.
    * `{:file, path}` — load a local `.u` file, for `mix unex.deploy`.

  Both go through the same `Unex.Runtime.extract/3`, so the same code deployed
  either way lands under the same root hash. `opts` are forwarded to it (see
  `Unex.Runtime.capture_source?/2`).

  The `entry_point` must be a thunk: `'{IO, Exception} Text`.
  """
  def deploy(name, source, entry_point, opts \\ []) do
    case Unex.Runtime.extract(source, entry_point, opts) do
      {:ok, %{root_value: root_value, codes: codes} = extract} ->
        store_codes(codes)
        root_hash = HashCache.put(HashCache, root_value)
        maybe_cache_source(root_hash, Map.get(extract, :source))
        cache_term_sources(Map.get(extract, :term_sources, %{}))
        cache_names(Map.get(extract, :names, %{}))
        cache_deps(root_hash, Map.get(extract, :deps, %{}))

        release(name, root_hash,
          project: share_project(source),
          entry_point: entry_point
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `Registry.Entry.project` is a `ucm pull` argument — it exists so the
  # dashboard can link back to Unison Share. A file deploy has no such thing, so
  # it records `nil` and the dashboard shows no source link. It is recorded
  # explicitly rather than omitted so that deploying a local file over a name
  # that was previously deployed from Share clears the now-wrong Share link;
  # see `merge_with_existing/2`.
  defp share_project({:share, project}), do: project
  defp share_project(project) when is_binary(project), do: project
  defp share_project({:file, _path}), do: nil

  # Stores the extractor's per-term dep graph in DepsCache. The map has
  # "#abc..." or "root" keys from the filenames; normalize them to match
  # HashCache's keying (no "#" prefix). The "root" entry gets associated
  # with the computed root_hash.
  defp cache_deps(root_hash, deps) when is_map(deps) do
    Enum.each(deps, fn {key, dep_list} ->
      normalized_key = if key == "root", do: root_hash, else: normalize_hash(key)
      normalized_deps = Enum.map(dep_list, &normalize_hash/1)
      Unex.Cluster.DepsCache.put(normalized_key, normalized_deps)
    end)
  end

  defp maybe_cache_source(_hash, nil), do: :ok

  defp maybe_cache_source(hash, source) when is_binary(source) do
    Unex.Cluster.SourceCache.put(hash, source)
  end

  defp cache_term_sources(map) when is_map(map) do
    Enum.each(map, fn {hash, source} ->
      Unex.Cluster.SourceCache.put(hash, source)
    end)
  end

  defp cache_names(map) when is_map(map) do
    Enum.each(map, fn {hash, name} ->
      Unex.Cluster.NameCache.put(hash, name)
    end)
  end

  defp store_codes(codes) do
    Enum.each(codes, fn {term_text, bytes} ->
      :ok = HashCache.put(HashCache, normalize_hash(term_text), bytes)
    end)
  end
end
