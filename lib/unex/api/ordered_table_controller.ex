defmodule Unex.API.OrderedTableController do
  @moduledoc """
  HTTP controller for ordered table operations.
  """

  alias Unex.Storage.OrderedTable
  alias Unex.API.Json

  def ensure(conn, db, table) do
    :ok = OrderedTable.ensure(db, table)
    Json.send_json(conn, 201, %{db: db, table: table})
  end

  def write(conn, db, table) do
    {:ok, %{"key" => key, "value" => value}} = Json.read_json(conn)
    :ok = OrderedTable.write(db, table, key, value)
    Json.send_json(conn, 200, %{key: key, value: value})
  end

  def read(conn, db, table, key) do
    case OrderedTable.read(db, table, key) do
      {:ok, value} -> Json.send_json(conn, 200, %{key: key, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  def delete(conn, db, table, key) do
    :ok = OrderedTable.delete(db, table, key)
    Json.send_json(conn, 200, %{key: key, deleted: true})
  end

  def scan(conn, db, table) do
    {:ok, %{"from" => from, "to" => to}} = Json.read_json(conn)
    results = OrderedTable.scan(db, table, from, to)
    formatted = Enum.map(results, fn {k, v} -> %{key: k, value: v} end)
    Json.send_json(conn, 200, %{results: formatted})
  end
end
