defmodule Unex.API.ServicesController do
  @moduledoc """
  HTTP handler functions for the services API endpoints.
  """

  alias Unex.API.Json
  alias Unex.Services

  def deploy(conn) do
    {:ok, params} = Json.read_json(conn)
    name = params["name"]
    source = params["source"]

    case Services.deploy(name, source) do
      {:ok, entry} ->
        Json.send_json(conn, 201, %{
          name: entry.name,
          hash: entry.hash,
          node: to_string(entry.node)
        })

      {:error, reason} ->
        Json.send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  def call(conn, name) do
    case Services.call(name) do
      {:ok, result} ->
        Json.send_json(conn, 200, %{
          stdout: result.stdout,
          stderr: result.stderr,
          exit_code: result.exit_code
        })

      {:error, :not_found} ->
        Json.send_json(conn, 404, %{error: "not_found"})

      {:error, reason} ->
        Json.send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  def list(conn) do
    entries = Services.list()

    services =
      Enum.map(entries, fn entry ->
        %{name: entry.name, hash: entry.hash, node: to_string(entry.node)}
      end)

    Json.send_json(conn, 200, %{services: services})
  end

  def undeploy(conn, name) do
    :ok = Services.undeploy(name)
    Json.send_json(conn, 200, %{status: "ok"})
  end
end
