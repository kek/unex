defmodule Unex.API.LogController do
  @moduledoc false
  alias Unex.API.Json
  alias Unex.Abilities.Log

  def append(conn) do
    {:ok, %{"level" => level, "message" => message} = body} = Json.read_json(conn)
    metadata = Map.get(body, "metadata", %{})
    Log.append(Unex.Abilities.Log, String.to_atom(level), message, metadata)
    Json.send_json(conn, 200, %{status: "logged"})
  end

  def recent(conn, n) do
    entries =
      Log.recent(Unex.Abilities.Log, String.to_integer(n))
      |> Enum.map(fn e ->
        %{
          level: Atom.to_string(e.level),
          message: e.message,
          metadata: e.metadata,
          timestamp: DateTime.to_iso8601(e.timestamp)
        }
      end)

    Json.send_json(conn, 200, %{entries: entries})
  end
end
