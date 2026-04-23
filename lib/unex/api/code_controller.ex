defmodule Unex.API.CodeController do
  @moduledoc """
  Serves serialized Unison `Code` bytes keyed by `Link.Term.toText` (without
  the leading `#`). Used by `Unex.Dispatcher` to fetch missing dependencies
  for a `Value` it's evaluating.

  GET /code/:termhash — returns raw `Code.serialize_v3` bytes, 404 if unknown.

  Stored in the cluster's shared `HashCache`.
  """

  alias Unex.Cluster.SyncServer
  alias Unex.API.Json

  def get(conn, term_hash) do
    key = normalize(term_hash)

    case SyncServer.resolve([key]) do
      {:ok, %{} = found} when is_map_key(found, key) ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, Map.fetch!(found, key))

      _ ->
        Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  defp normalize("#" <> rest), do: rest
  defp normalize(hash), do: hash
end
