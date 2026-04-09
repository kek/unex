defmodule Unex.API.BytecodeController do
  @moduledoc """
  HTTP handler for pushing and pulling bytecode blobs, keyed by hash.

  PUT /bytecode/:hash  — store raw bytecode bytes under the given hash
  GET /bytecode/:hash  — retrieve bytecode bytes by hash

  The hash is the *Unison hash* of the compiled definition — supplied by the
  client (e.g. from `Link.Term.toText (termLink myFn)`), not computed locally
  from the bytes. Hashes may include a leading '#' (Unison hash format); it is
  stripped before storage so '#abc123' and 'abc123' refer to the same entry.
  """

  alias Unex.Cluster.HashCache
  alias Unex.API.Json

  def put(conn, hash) do
    hash = normalize_hash(hash)

    # Plug.Parsers is configured with pass: ["application/octet-stream"],
    # which means it does not read or consume binary request bodies.
    # read_body/1 therefore receives the full body here.
    case Plug.Conn.read_body(conn, length: 50_000_000) do
      {:ok, bytes, conn} ->
        HashCache.put(HashCache, hash, bytes)
        Json.send_json(conn, 201, %{hash: hash})

      {:more, _partial, conn} ->
        Json.send_json(conn, 413, %{error: "payload_too_large"})

      {:error, reason} ->
        Json.send_json(conn, 400, %{error: inspect(reason)})
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
