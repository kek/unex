defmodule Unex.API.ServicesController do
  @moduledoc """
  HTTP handler functions for the services API endpoints.
  """

  alias Unex.API.Json
  alias Unex.Services

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

  def release(conn, name) do
    {:ok, params} = Json.read_json(conn)

    case params["hash"] do
      nil ->
        Json.send_json(conn, 422, %{error: "hash is required"})

      hash ->
        {:ok, _entry} = Services.release(name, hash)
        Json.send_json(conn, 200, %{name: name, hash: hash})
    end
  end

  def deploy(conn, name) do
    {:ok, params} = Json.read_json(conn)

    require Logger

    with entry_point when is_binary(entry_point) <- params["entry"],
         project when is_binary(project) <- params["project"] do
      Logger.info("Deploy #{name}: project=#{project} entry=#{entry_point}")

      case Services.deploy(name, project, entry_point) do
        {:ok, entry} ->
          Json.send_json(conn, 200, %{name: name, hash: entry.hash})

        {:error, reason} ->
          Logger.error("Deploy #{name} failed:\n#{reason}")
          Json.send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      _ -> Json.send_json(conn, 422, %{error: "entry and project are required"})
    end
  end
end
