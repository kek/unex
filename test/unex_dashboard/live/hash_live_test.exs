defmodule Unex.Dashboard.HashLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  @endpoint Unex.Dashboard.Endpoint

  setup do
    Application.put_env(:unex, :dashboard_username, "admin")
    Application.put_env(:unex, :dashboard_password, "unex")
    start_supervised!(Unex.Dashboard.Endpoint)
    :ok
  end

  defp authed_conn do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("admin:unex"))
  end

  test "renders blob info when hash exists" do
    hash = Unex.Cluster.HashCache.put("payload bytes")
    {:ok, _view, html} = live(authed_conn(), "/hash/#{hash}")
    assert html =~ hash
    assert html =~ "13 bytes"
  end

  test "renders not-found when hash is missing" do
    {:ok, _view, html} = live(authed_conn(), "/hash/deadbeef")
    assert html =~ "not found"
  end
end
