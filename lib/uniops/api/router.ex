defmodule Uniops.API.Router do
  @moduledoc """
  HTTP API router for Uniops storage operations.
  """

  use Plug.Router

  alias Uniops.API.{
    DatabaseController,
    OrderedTableController,
    CellController,
    TransactionController,
    ServicesController,
    Json
  }

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  get "/health" do
    Json.send_json(conn, 200, %{status: "ok"})
  end

  post "/databases" do
    DatabaseController.create(conn)
  end

  get "/databases" do
    DatabaseController.list(conn)
  end

  post "/databases/:db/tables/:table" do
    OrderedTableController.ensure(conn, db, table)
  end

  post "/databases/:db/tables/:table/write" do
    OrderedTableController.write(conn, db, table)
  end

  get "/databases/:db/tables/:table/read/:key" do
    OrderedTableController.read(conn, db, table, key)
  end

  delete "/databases/:db/tables/:table/delete/:key" do
    OrderedTableController.delete(conn, db, table, key)
  end

  post "/databases/:db/tables/:table/scan" do
    OrderedTableController.scan(conn, db, table)
  end

  post "/databases/:db/cells/:name/write" do
    CellController.write(conn, db, name)
  end

  get "/databases/:db/cells/:name/read" do
    CellController.read(conn, db, name)
  end

  post "/databases/:db/tx" do
    TransactionController.execute(conn, db)
  end

  # Services routes

  post "/services/deploy" do
    ServicesController.deploy(conn)
  end

  post "/services/:name/call" do
    ServicesController.call(conn, name)
  end

  get "/services" do
    ServicesController.list(conn)
  end

  delete "/services/:name" do
    ServicesController.undeploy(conn, name)
  end

  match _ do
    Json.send_json(conn, 404, %{error: "not_found"})
  end
end
