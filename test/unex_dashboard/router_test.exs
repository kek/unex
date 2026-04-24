defmodule Unex.Dashboard.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  setup do
    Application.put_env(:unex, :dashboard_username, "admin")
    Application.put_env(:unex, :dashboard_password, "unex")

    start_supervised!(Unex.Dashboard.Endpoint)
    :ok
  end

  test "unauthenticated request returns 401" do
    conn = Phoenix.ConnTest.build_conn(:get, "/")
    conn = Unex.Dashboard.Endpoint.call(conn, Unex.Dashboard.Endpoint.init([]))
    assert conn.status == 401
  end

  test "authenticated root redirects to /dashboard" do
    creds = Base.encode64("admin:unex")

    conn =
      Phoenix.ConnTest.build_conn(:get, "/")
      |> put_req_header("authorization", "Basic #{creds}")

    conn = Unex.Dashboard.Endpoint.call(conn, Unex.Dashboard.Endpoint.init([]))
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/dashboard"]
  end
end
