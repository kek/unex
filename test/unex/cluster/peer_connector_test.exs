defmodule Unex.Cluster.PeerConnectorTest do
  use ExUnit.Case, async: false

  alias Unex.Cluster.PeerConnector

  describe "parse_peers/1" do
    test "converts string peer names to atoms" do
      assert PeerConnector.parse_peers(["a@host1", "b@host2"]) == [:a@host1, :b@host2]
    end

    test "handles empty list" do
      assert PeerConnector.parse_peers([]) == []
    end
  end

  describe "start_link/1" do
    test "starts with empty peer list" do
      pid = start_supervised!({PeerConnector, peers: [], name: :test_peer_connector})
      assert Process.alive?(pid)
    end

    test "starts with unreachable peers without crashing" do
      pid =
        start_supervised!(
          {PeerConnector,
           peers: ["nonexistent@nowhere"],
           name: :test_peer_connector_unreachable,
           connect_interval: 100}
        )

      Process.sleep(200)
      assert Process.alive?(pid)
    end
  end

  describe "status/1" do
    test "reports peer connection status" do
      pid = start_supervised!({PeerConnector, peers: [], name: :test_status_connector})
      status = PeerConnector.status(pid)
      assert is_map(status)
      assert status.peers == []
    end
  end

  describe "broadcasts" do
    setup do
      Phoenix.PubSub.subscribe(Unex.PubSub, Unex.Dashboard.Events.topic_cluster())
      :ok
    end

    test "record_up broadcasts :node_up and adds peer to connected set" do
      state = %{
        peers: [:a@h],
        connected: MapSet.new(),
        backoffs: %{},
        base_interval: 1000
      }

      new_state = Unex.Cluster.PeerConnector.record_up(state, :a@h)
      assert MapSet.member?(new_state.connected, :a@h)
      assert_receive {:cluster, {:node_up, :a@h}}, 500
    end

    test "record_up is idempotent — broadcasts again but set already has peer" do
      state = %{
        peers: [:a@h],
        connected: MapSet.new([:a@h]),
        backoffs: %{},
        base_interval: 1000
      }

      new_state = Unex.Cluster.PeerConnector.record_up(state, :a@h)
      assert MapSet.member?(new_state.connected, :a@h)
      assert_receive {:cluster, {:node_up, :a@h}}, 500
    end
  end
end
