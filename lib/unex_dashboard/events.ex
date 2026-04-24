defmodule Unex.Dashboard.Events do
  @moduledoc """
  PubSub topic names and broadcast helpers used by core to publish
  observable events. This module is in the dashboard namespace but is
  safe for core to call — it depends only on Phoenix.PubSub, which is
  always started by Unex.Application.

  If no dashboard is running, broadcasts are no-ops with zero subscribers.
  """

  @pubsub Unex.PubSub

  @topic_hashcache "hashcache"
  @topic_services "services"
  @topic_cluster "cluster"

  def topic_hashcache, do: @topic_hashcache
  def topic_services, do: @topic_services
  def topic_cluster, do: @topic_cluster

  def broadcast_hashcache(event),
    do: Phoenix.PubSub.broadcast(@pubsub, @topic_hashcache, {:hashcache, event})

  def broadcast_services(event),
    do: Phoenix.PubSub.broadcast(@pubsub, @topic_services, {:services, event})

  def broadcast_cluster(event),
    do: Phoenix.PubSub.broadcast(@pubsub, @topic_cluster, {:cluster, event})
end
