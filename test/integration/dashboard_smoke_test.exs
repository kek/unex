defmodule Unex.Integration.DashboardSmokeTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  @creds Base.encode64("admin:unex")

  setup do
    Application.put_env(:unex, :dashboard_username, "admin")
    Application.put_env(:unex, :dashboard_password, "unex")
    start_supervised!(Unex.Dashboard.Endpoint)
    :ok
  end

  defp authed_get(path) do
    build_conn(:get, path)
    |> put_req_header("authorization", "Basic #{@creds}")
    |> Unex.Dashboard.Endpoint.call(Unex.Dashboard.Endpoint.init([]))
  end

  test "/ redirects to /dashboard with auth" do
    conn = authed_get("/")
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/dashboard"]
  end

  test "/dashboard returns 200 or 302" do
    conn = authed_get("/dashboard")
    # LiveDashboard redirects to /dashboard/NODE/home on first hit.
    assert conn.status in [200, 302]
  end

  test "dashboard pages (services/cluster/swarm/hash) mount under the current node" do
    node_seg = URI.encode_www_form(Atom.to_string(node()))

    for page <- ~w(services cluster swarm code hash) do
      path = "/dashboard/#{node_seg}/#{page}"
      conn = authed_get(path)
      assert conn.status == 200, "#{path} returned #{conn.status}: #{inspect(conn.resp_body)}"
    end
  end

  test "unauthenticated request returns 401" do
    conn =
      build_conn(:get, "/")
      |> Unex.Dashboard.Endpoint.call(Unex.Dashboard.Endpoint.init([]))

    assert conn.status == 401
  end
end
