defmodule Unex.API.Auth do
  @moduledoc """
  Plug that enforces bearer token authentication on all API routes except /health.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, _opts) do
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
