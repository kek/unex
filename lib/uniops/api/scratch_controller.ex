defmodule Uniops.API.ScratchController do
  @moduledoc false
  alias Uniops.API.Json
  alias Uniops.Abilities.Scratch

  def put(conn, key) do
    {:ok, %{"value" => value}} = Json.read_json(conn)
    :ok = Scratch.put(Uniops.Abilities.Scratch, key, value)
    Json.send_json(conn, 200, %{key: key})
  end

  def get(conn, key) do
    case Scratch.get(Uniops.Abilities.Scratch, key) do
      {:ok, value} -> Json.send_json(conn, 200, %{key: key, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end
end
