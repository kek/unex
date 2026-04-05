defmodule Uniops.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    mnesia_dir = Application.get_env(:uniops, :mnesia_dir)
    if mnesia_dir, do: Uniops.Storage.Schema.init(mnesia_dir)

    children = cluster_children() ++ peer_children() ++ api_children()
    Supervisor.start_link(children, strategy: :one_for_one, name: Uniops.Supervisor)
  end

  defp cluster_children do
    [
      Uniops.Cluster.HashCache,
      Uniops.Cluster.SyncServer,
      Uniops.Services.Registry,
      Uniops.Abilities.Scratch,
      Uniops.Abilities.Log
    ]
  end

  defp peer_children do
    peers = Application.get_env(:uniops, :peers, [])

    if peers != [] do
      [{Uniops.Cluster.PeerConnector, peers: peers}]
    else
      []
    end
  end

  defp api_children do
    if Application.get_env(:uniops, :start_api, false) do
      port = Application.get_env(:uniops, :api_port, 4040)
      [{Bandit, plug: Uniops.API.Router, port: port}]
    else
      []
    end
  end
end
