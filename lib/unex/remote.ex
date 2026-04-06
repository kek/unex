defmodule Unex.Remote do
  @moduledoc """
  Coordinates bytecode execution on local or remote nodes.

  Combines HashCache, SyncServer, and Runner to resolve bytecode by hash
  and execute it, either locally or on a specified cluster node via RPC.
  """

  alias Unex.Cluster.SyncServer
  alias Unex.Runner

  @default_timeout 60_000

  @doc """
  Executes bytecode identified by `hash`.

  Options:
    - `:node` — target node (default: current node)
    - `:timeout` — RPC and execution timeout in ms (default: 60_000)
    - `:args` — list of string arguments to pass to the program
  """
  def execute(hash, opts \\ []) do
    target = Keyword.get(opts, :node, node())
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    if target == node() do
      do_execute(hash, opts)
    else
      case :rpc.call(target, __MODULE__, :do_execute, [hash, opts], timeout) do
        {:badrpc, reason} -> {:error, {:rpc_failed, target, reason}}
        result -> result
      end
    end
  end

  @doc """
  Picks a random peer from `Node.list()` and executes there.
  Falls back to local execution if no peers are connected.
  """
  def submit(hash, opts \\ []) do
    case Node.list() do
      [] ->
        execute(hash, opts)

      peers ->
        target = Enum.random(peers)
        execute(hash, Keyword.put(opts, :node, target))
    end
  end

  @doc """
  Resolves bytecode for `hash` and executes it locally.

  Public because it is called via RPC from remote nodes.
  """
  def do_execute(hash, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "unex_exec_#{hash}.uc")

    with {:ok, resolved} <- SyncServer.resolve([hash]),
         data when is_binary(data) <- Map.get(resolved, hash) do
      try do
        File.write!(path, data)
        Runner.run_compiled(path, Keyword.take(opts, [:timeout, :args]))
      after
        File.rm(path)
      end
    else
      {:error, _} = err -> err
      nil -> {:error, {:missing, hash}}
    end
  end
end
