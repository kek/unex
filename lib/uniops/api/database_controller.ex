defmodule Uniops.API.DatabaseController do
  @moduledoc """
  HTTP controller for database management operations.
  """

  alias Uniops.Storage.Database
  alias Uniops.API.Json

  def create(conn) do
    {:ok, %{"name" => name}} = Json.read_json(conn)
    :ok = Database.create(name)
    Json.send_json(conn, 201, %{name: name})
  end

  def list(conn) do
    databases = Database.list()
    Json.send_json(conn, 200, %{databases: databases})
  end
end
