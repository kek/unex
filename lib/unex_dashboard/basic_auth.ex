defmodule Unex.Dashboard.BasicAuth do
  @moduledoc """
  HTTP Basic Auth plug for the dashboard. Credentials are read from
  application config (`:dashboard_username`, `:dashboard_password`) on
  every request so that runtime-config changes take effect. Tests can
  override by passing `username:`/`password:` as plug opts.
  """

  import Plug.Conn

  def init(opts) do
    %{
      username_override: Keyword.get(opts, :username),
      password_override: Keyword.get(opts, :password),
      realm: Keyword.get(opts, :realm, "Unex Dashboard")
    }
  end

  def call(conn, %{username_override: uo, password_override: po, realm: realm}) do
    u = uo || Application.get_env(:unex, :dashboard_username)
    p = po || Application.get_env(:unex, :dashboard_password)

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
