defmodule Unex.Dashboard.ServicesLiveTest do
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

  test "renders empty state" do
    {:ok, _view, html} = live(authed_conn(), "/services")
    assert html =~ "Services"
    assert html =~ "No services deployed"
  end

  test "live-updates when a service is registered" do
    {:ok, view, _html} = live(authed_conn(), "/services")

    Unex.Dashboard.Events.broadcast_services({:registered, "greeter", "abc123", node()})

    assert render(view) =~ "greeter"
    assert render(view) =~ "abc123"
  end
end
