defmodule Unex.API.BytecodeController do
  @moduledoc """
  HTTP handler for pushing and pulling bytecode blobs, keyed by hash.

  POST /bytecode  — push bytecode bytes (hex JSON); server computes SHA256 hash
  GET /bytecode/:hash  — retrieve bytecode bytes by hash

  Hashes may include a leading '#' (Unison hash format); it is stripped before
  storage so '#abc123' and 'abc123' refer to the same entry.
  """

  alias Unex.Cluster.HashCache
  alias Unex.API.Json

  def push(conn) do
    with {:ok, body} <- Json.read_json(conn),
         %{"data" => hex} <- body,
         {:ok, bytes} <- Base.decode16(hex, case: :mixed) do
      hash = HashCache.put(HashCache, bytes)
      Json.send_json(conn, 201, %{hash: hash})
    else
      _ -> Json.send_json(conn, 400, %{error: "invalid_payload"})
    end
  end

  def get(conn, hash) do
    hash = normalize_hash(hash)

    case HashCache.get(HashCache, hash) do
      {:ok, bytes} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, bytes)

      :not_found ->
        Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  defp normalize_hash("#" <> rest), do: rest
  defp normalize_hash(hash), do: hash
end
