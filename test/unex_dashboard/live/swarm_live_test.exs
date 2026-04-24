defmodule Unex.Dashboard.SwarmLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint Unex.Dashboard.Endpoint

  setup do
    Application.put_env(:unex, :dashboard_username, "admin")
    Application.put_env(:unex, :dashboard_password, "unex")
    start_supervised!(Unex.Dashboard.Endpoint)
    :ok
  end

  defp authed_conn do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("admin:unex"))
  end

  test "renders empty swarm state" do
    {:ok, _view, html} = live(authed_conn(), "/swarm")
    assert html =~ "Swarm"
    assert html =~ "0 in-flight"
  end

  test "increments and decrements in-flight on service call events" do
    {:ok, view, _html} = live(authed_conn(), "/swarm")

    Unex.Dashboard.Events.broadcast_services({:call_started, "agent", node()})
    assert render(view) =~ "1 in-flight"

    Unex.Dashboard.Events.broadcast_services({:call_finished, "agent", node()})
    assert render(view) =~ "0 in-flight"
  end
end
