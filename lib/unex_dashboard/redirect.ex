defmodule Unex.Dashboard.Redirect do
  @moduledoc "Tiny controller that redirects `/` to `/dashboard`."

  import Plug.Conn

  def init(action), do: action

  def call(conn, :to_dashboard) do
    conn
    |> put_resp_header("location", "/dashboard")
    |> send_resp(302, "")
    |> halt()
  end
end
