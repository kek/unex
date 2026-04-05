defmodule Uniops.Cluster.PeerConnectorTest do
  use ExUnit.Case, async: false

  alias Uniops.Cluster.PeerConnector

  describe "parse_peers/1" do
    test "converts string peer names to atoms" do
      assert PeerConnector.parse_peers(["a@host1", "b@host2"]) == [:"a@host1", :"b@host2"]
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
end
