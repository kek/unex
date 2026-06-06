defmodule Unex.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    mnesia_dir = Application.get_env(:unex, :mnesia_dir)
    if mnesia_dir, do: Unex.Storage.Schema.init(mnesia_dir)

    children =
      pubsub_children() ++
        cluster_children() ++
        peer_children() ++
        api_children() ++
        dashboard_children()

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Unex.Supervisor)
    maybe_start_code_reloader()
    result
  end

  defp maybe_start_code_reloader do
    if Application.get_env(:unex, :code_reloader, false) and
         Code.ensure_loaded?(ExSync) do
      {:ok, _} = Application.ensure_all_started(:exsync)
    end
  end

  defp pubsub_children do
    [{Phoenix.PubSub, name: Unex.PubSub}]
  end

  defp cluster_children do
    persist_services? = Application.get_env(:unex, :mnesia_dir) != nil
    hash_cache_dir = Application.get_env(:unex, :hash_cache_dir)

    base = [
      {Unex.Cluster.HashCache, dir: hash_cache_dir},
      Unex.Cluster.SourceCache,
      Unex.Cluster.NameCache,
      Unex.Cluster.DepsCache,
      Unex.Cluster.SyncServer,
      {Unex.Services.Registry, persist?: persist_services?},
      Unex.Abilities.Scratch,
      Unex.Abilities.Log,
      Unex.Runtime
    ]

    if Application.get_env(:unex, :start_dispatcher, true) do
      pool_size = Application.get_env(:unex, :dispatcher_pool_size, 4)
      base ++ [{Unex.Dispatcher.Pool, pool_size: pool_size}]
    else
      base
    end
  end

  defp peer_children do
    peers = Application.get_env(:unex, :peers, [])

    if peers != [] do
      [{Unex.Cluster.PeerConnector, peers: peers}]
    else
      []
    end
  end

  defp api_children do
    if Application.get_env(:unex, :start_api, false) do
      port = Application.get_env(:unex, :api_port, 4040)
      [{Bandit, plug: Unex.API.Router, port: port}]
    else
      []
    end
  end

  defp dashboard_children do
    if Application.get_env(:unex, :start_dashboard, false) do
      Application.get_env(:unex, :dashboard_children, [])
    else
      []
    end
  end
end
