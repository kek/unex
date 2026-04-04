defmodule Uniops.API.Json do
  @moduledoc """
  JSON request/response helpers for the HTTP API.
  """

  import Plug.Conn

  @doc """
  Sends a JSON response with the given status code and body.
  Sets content-type to application/json.
  """
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc """
  Reads parsed JSON body params from the connection.
  Requires Plug.Parsers to have already parsed the body.
  Returns `{:ok, params}` or `{:error, :not_parsed}`.
  """
  def read_json(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:error, :not_parsed}
      params -> {:ok, params}
    end
  end
end
