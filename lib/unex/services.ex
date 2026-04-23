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
    case Registry.resolve(name) do
      {:ok, %Entry{} = entry} -> execute(entry, opts)
      :not_found -> {:error, :not_found}
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
    with {:ok, resolved} <- SyncServer.resolve([hash]),
         data when is_binary(data) <- Map.get(resolved, hash) do
      case Unex.Dispatcher.eval(data, timeout) do
        {:ok, text} -> {:ok, %Result{stdout: text, stderr: "", exit_code: 0}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = err -> err
      nil -> {:error, {:missing, hash}}
    end
  end

  @doc """
  Points a service name at an existing root-value hash.

  Deploys push the root `Value` bytes and `Code` bytes into `HashCache` first,
  then `release` moves the name pointer to any existing hash.
  """
  def release(name, hash) do
    Registry.register(name, normalize_hash(hash), node())
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
      {:ok, %{root_value: root_value, codes: codes}} ->
        store_codes(codes)
        root_hash = HashCache.put(HashCache, root_value)
        release(name, root_hash)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_codes(codes) do
    Enum.each(codes, fn {term_text, bytes} ->
      :ok = HashCache.put(HashCache, normalize_hash(term_text), bytes)
    end)
  end
end
