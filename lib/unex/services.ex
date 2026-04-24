defmodule Unex.Services do
  @moduledoc """
  Public API for deploying, calling, listing, and undeploying named services.

  A service is a Unison thunk registered under a human-readable name. Deploys
  pull the project, extract a serialized `Value` for the entry point plus all
  transitively reachable `Code` bytes, and store them in the cluster's shared
  `HashCache`. Calls dispatch the root `Value` through a long-lived
  `Unex.Dispatcher` process which evaluates it and fetches missing `Code`
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
  local `Unex.Dispatcher` for evaluation. Public because it is called via
  RPC from remote nodes.
  """
  def eval_local(hash, timeout) do
    cond do
      not Unex.Dispatcher.running?() ->
        {:error, :dispatcher_not_started}

      true ->
        with {:ok, resolved} <- SyncServer.resolve([hash]),
             data when is_binary(data) <- Map.get(resolved, hash) do
          case Unex.Dispatcher.eval(Unex.Dispatcher, data, timeout) do
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
  defp merge_with_existing(name, opts) do
    needs_merge? =
      is_nil(Keyword.get(opts, :project)) or is_nil(Keyword.get(opts, :entry_point))

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
  Deploys a service by pulling from Unison Share, extracting the entry
  point's serialized `Value`, and storing all transitively reachable `Code`
  bytes. Returns `{:ok, %Entry{}}` on success.

  The `entry_point` must be a thunk: `'{IO, Exception} Text`.
  """
  def deploy(name, project, entry_point) do
    case Unex.Runtime.extract(project, entry_point) do
      {:ok, %{root_value: root_value, codes: codes} = extract} ->
        store_codes(codes)
        root_hash = HashCache.put(HashCache, root_value)
        maybe_cache_source(root_hash, Map.get(extract, :source))
        cache_deps(root_hash, Map.get(extract, :deps, %{}))
        release(name, root_hash, project: project, entry_point: entry_point)

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  defp store_codes(codes) do
    Enum.each(codes, fn {term_text, bytes} ->
      :ok = HashCache.put(HashCache, normalize_hash(term_text), bytes)
    end)
  end
end
