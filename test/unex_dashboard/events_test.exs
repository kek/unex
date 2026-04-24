defmodule Unex.Dashboard.EventsTest do
  use ExUnit.Case, async: true

  alias Unex.Dashboard.Events

  setup do
    Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_hashcache())
    Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_services())
    Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_cluster())
    :ok
  end

  test "broadcast_hashcache/1 publishes on the hashcache topic" do
    Events.broadcast_hashcache({:put, "abc123", 42})
    assert_receive {:hashcache, {:put, "abc123", 42}}, 500
  end

  test "broadcast_services/1 publishes on the services topic" do
    Events.broadcast_services({:deployed, "greeter", "abc"})
    assert_receive {:services, {:deployed, "greeter", "abc"}}, 500
  end

  test "broadcast_cluster/1 publishes on the cluster topic" do
    Events.broadcast_cluster({:node_up, :a@host})
    assert_receive {:cluster, {:node_up, :a@host}}, 500
  end
end
