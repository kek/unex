defmodule Unex.API.Auth do
  @moduledoc """
  Plug that enforces bearer token authentication on all API routes except /health.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/health"} = conn, _opts), do: conn

  def call(%{method: "GET", request_path: path} = conn, _opts) do
    case service_name(path) do
      {:ok, name} ->
        if service_registered?(name), do: conn, else: call_auth(conn)

      :no ->
        call_auth(conn)
    end
  end

  def call(conn, _opts), do: call_auth(conn)

  defp service_name("/" <> rest) when rest != "" do
    if String.contains?(rest, "/"), do: :no, else: {:ok, rest}
  end

  defp service_name(_), do: :no

  # Use resolve (local + peer fallback) so the auth bypass matches the
  # service-reachability semantics: any node that can serve `/<name>`
  # via the dispatcher should also let the request through unauthenticated.
  defp service_registered?(name) do
    case Unex.Services.Registry.resolve(name) do
      {:ok, _} -> true
      :not_found -> false
    end
  catch
    :exit, _ -> false
  end

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
