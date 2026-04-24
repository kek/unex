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

  test "/ returns 200 with auth" do
    conn = authed_get("/")
    assert conn.status == 200
    assert conn.resp_body =~ "Unex Dashboard"
  end

  test "/services, /cluster, /swarm all return 200" do
    for path <- ["/services", "/cluster", "/swarm"] do
      conn = authed_get(path)
      assert conn.status == 200, "#{path} returned #{conn.status}: #{inspect(conn.resp_body)}"
    end
  end

  test "/hash/:id returns 200 (missing blob shows not-found copy)" do
    conn = authed_get("/hash/deadbeef")
    assert conn.status == 200
    assert conn.resp_body =~ "not found"
  end

  test "/dashboard (Phoenix LiveDashboard) returns 200 or 302" do
    # LiveDashboard may redirect to /dashboard/home; either is acceptable.
    conn = authed_get("/dashboard")
    assert conn.status in [200, 302]
  end

  test "unauthenticated request returns 401" do
    conn =
      build_conn(:get, "/")
      |> Unex.Dashboard.Endpoint.call(Unex.Dashboard.Endpoint.init([]))

    assert conn.status == 401
  end
end
