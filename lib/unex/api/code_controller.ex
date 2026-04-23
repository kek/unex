defmodule Unex.API.CodeController do
  @moduledoc """
  Serves serialized Unison `Code` bytes keyed by `Link.Term.toText` (without
  the leading `#`). Used by `Unex.Dispatcher` to fetch missing dependencies
  for a `Value` it's evaluating.

  GET /code/:termhash — returns raw `Code.serialize_v3` bytes, 404 if unknown.

  Stored in the cluster's shared `HashCache`.
  """

  alias Unex.Cluster.HashCache
  alias Unex.API.Json

  def get(conn, term_hash) do
    case HashCache.get(HashCache, normalize(term_hash)) do
      {:ok, bytes} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, bytes)

      :not_found ->
        Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  defp normalize("#" <> rest), do: rest
  defp normalize(hash), do: hash
end
