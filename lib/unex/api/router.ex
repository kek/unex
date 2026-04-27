defmodule Unex.API.Router do
  @moduledoc """
  HTTP API router for Unex storage operations.
  """

  use Plug.Router

  alias Unex.API.{
    DatabaseController,
    OrderedTableController,
    CellController,
    TransactionController,
    ServicesController,
    BytecodeController,
    CodeController,
    ConfigController,
    BlobsController,
    ScratchController,
    LogController,
    Json
  }

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["application/octet-stream"]
  )

  plug(Unex.API.Auth)

  plug(:match)
  plug(:dispatch)

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

  # Bytecode routes
  post "/bytecode" do
    BytecodeController.push(conn)
  end

  get "/bytecode/:hash" do
    BytecodeController.get(conn, hash)
  end

  # Unison Code bytes keyed by Link.Term hash (served to the dispatcher).
  get "/code/:termhash" do
    CodeController.get(conn, termhash)
  end

  # Services routes

  post "/services/:name/deploy" do
    ServicesController.deploy(conn, name)
  end

  post "/services/:name/release" do
    ServicesController.release(conn, name)
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

  # Config routes
  post "/config/:env/:key" do
    ConfigController.set(conn, env, key)
  end

  get "/config/:env/:key" do
    ConfigController.get(conn, env, key)
  end

  get "/config/:env" do
    ConfigController.list(conn, env)
  end

  # Blobs routes — list MUST come before the *key wildcard
  post "/blobs/:db/list" do
    BlobsController.list(conn, db)
  end

  post "/blobs/:db/*key" do
    key_str = Enum.join(key, "/")
    BlobsController.write(conn, db, key_str)
  end

  get "/blobs/:db/*key" do
    key_str = Enum.join(key, "/")
    BlobsController.read(conn, db, key_str)
  end

  # Scratch routes
  post "/scratch/:key" do
    ScratchController.put(conn, key)
  end

  get "/scratch/:key" do
    ScratchController.get(conn, key)
  end

  # Log routes
  post "/log" do
    LogController.append(conn)
  end

  get "/log/recent/:n" do
    LogController.recent(conn, n)
  end

  # Service web endpoint — kept last so specific routes above take precedence.
  get "/:name" do
    ServicesController.web(conn, name)
  end

  match _ do
    Json.send_json(conn, 404, %{error: "not_found"})
  end
end
