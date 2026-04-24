defmodule Unex.Dashboard.BasicAuth do
  @moduledoc """
  HTTP Basic Auth plug for the dashboard. Credentials come from
  application config (`:dashboard_username`, `:dashboard_password`)
  and can be overridden per-call via init opts (for tests).
  """

  import Plug.Conn

  def init(opts) do
    %{
      username: Keyword.get(opts, :username) || Application.get_env(:unex, :dashboard_username),
      password: Keyword.get(opts, :password) || Application.get_env(:unex, :dashboard_password),
      realm: Keyword.get(opts, :realm, "Unex Dashboard")
    }
  end

  def call(conn, %{username: u, password: p, realm: realm}) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [user, pass] <- String.split(decoded, ":", parts: 2),
         true <- Plug.Crypto.secure_compare(user, u) and Plug.Crypto.secure_compare(pass, p) do
      conn
    else
      _ -> unauthorized(conn, realm)
    end
  end

  defp unauthorized(conn, realm) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="#{realm}"))
    |> send_resp(401, "Unauthorized")
    |> halt()
  end
end
