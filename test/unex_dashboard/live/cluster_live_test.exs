defmodule Unex.Dashboard.ClusterLiveTest do
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

  test "renders graph container with ClusterGraph hook" do
    {:ok, _view, html} = live(authed_conn(), "/cluster")
    assert html =~ ~s(phx-hook="ClusterGraph")
    assert html =~ "Cluster"
  end

  test "renders current node name" do
    {:ok, _view, html} = live(authed_conn(), "/cluster")
    assert html =~ Atom.to_string(node())
  end
end
