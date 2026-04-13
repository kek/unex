defmodule Unex.API.Auth do
  @moduledoc """
  Plug that enforces bearer token authentication on all API routes except /health.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/health"} = conn, _opts), do: conn

  def call(%{request_path: "/services/" <> rest, method: "GET"} = conn, _opts) do
    if String.ends_with?(rest, "/web"), do: conn, else: call_auth(conn)
  end

  def call(conn, _opts), do: call_auth(conn)

  defp call_auth(conn) do
    secret = Application.get_env(:unex, :api_secret)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token == secret ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end
end
