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

    Supervisor.start_link(children, strategy: :one_for_one, name: Unex.Supervisor)
  end

  defp pubsub_children do
    [{Phoenix.PubSub, name: Unex.PubSub}]
  end

  defp cluster_children do
    base = [
      Unex.Cluster.HashCache,
      Unex.Cluster.SourceCache,
      Unex.Cluster.SyncServer,
      Unex.Services.Registry,
      Unex.Abilities.Scratch,
      Unex.Abilities.Log,
      Unex.Runtime
    ]

    if Application.get_env(:unex, :start_dispatcher, true) do
      base ++ [Unex.Dispatcher]
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
