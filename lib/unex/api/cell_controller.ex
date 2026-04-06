defmodule Unex.API.CellController do
  @moduledoc """
  HTTP controller for cell operations.
  """

  alias Unex.Storage.Cell
  alias Unex.API.Json

  def write(conn, db, name) do
    {:ok, %{"value" => value}} = Json.read_json(conn)
    :ok = Cell.write(db, name, value)
    Json.send_json(conn, 200, %{name: name, value: value})
  end

  def read(conn, db, name) do
    case Cell.read(db, name) do
      {:ok, value} -> Json.send_json(conn, 200, %{name: name, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end
end
