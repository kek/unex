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

  def web(conn, name) do
    case Services.call(name) do
      {:ok, result} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, result.stdout)

      {:error, :not_found} ->
        conn |> Plug.Conn.send_resp(404, "Service not found")

      {:error, _reason} ->
        conn |> Plug.Conn.send_resp(500, "Internal error")
    end
  end

  @doc """
  `POST /services/:name/deploy`.

  The body names the entry point plus exactly one origin for its source:

      {"entry": "mainCounter", "project": "@kek/counter"}    # pull from Share
      {"entry": "mainCounter", "source": "<.u file text>"}   # a local file

  `project` is the original, unchanged path. `source` is what `mix unex.deploy`
  sends, and it is the whole point of it: no Unison Share round trip in the
  edit → deploy → look loop. Both end up in `Unex.Runtime.extract/3`, which
  differs between them by one UCM command, so the same code deployed either way
  gets the same root hash.

  `source` carries the file's *text* rather than a path so that the endpoint does
  not assume the client shares a filesystem with the server (and does not turn
  an API token into "read any file on the box"). UCM ingests source through
  `load <path>`, so the text is written to a temporary `.u` file here — that is
  the only reason this function touches the filesystem.

  Optional `"capture_source": true | false` overrides whether the dashboard
  source-capture stages run; see `Unex.Runtime.capture_source?/2` for the
  defaults and what they cost.
  """
  def deploy(conn, name) do
    {:ok, params} = Json.read_json(conn)

    case origin(params, name) do
      {:ok, entry_point, source, cleanup} ->
        try do
          run_deploy(conn, name, source, entry_point, deploy_opts(params))
        after
          cleanup.()
        end

      {:error, message} ->
        Json.send_json(conn, 422, %{error: message})
    end
  end

  defp run_deploy(conn, name, source, entry_point, opts) do
    require Logger

    Logger.info("Deploy #{name}: source=#{inspect(source)} entry=#{entry_point}")

    case Services.deploy(name, source, entry_point, opts) do
      {:ok, entry} ->
        Json.send_json(conn, 200, %{name: name, hash: entry.hash})

      {:error, reason} ->
        Logger.error("Deploy #{name} failed:\n#{reason}")
        Json.send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Returns `{:ok, entry_point, source, cleanup}`, where `cleanup` removes the
  # temporary directory an inline `source` was written to (and is a no-op for a
  # Share deploy).
  defp origin(params, name) do
    entry_point = params["entry"]

    cond do
      not is_binary(entry_point) ->
        {:error, "entry is required"}

      is_binary(params["source"]) ->
        {path, cleanup} = write_temp_source(name, params["source"])
        {:ok, entry_point, {:file, path}, cleanup}

      is_binary(params["project"]) ->
        {:ok, entry_point, {:share, params["project"]}, fn -> :ok end}

      true ->
        {:error, "entry and one of project or source are required"}
    end
  end

  # The basename becomes part of UCM's parse errors, so it is worth making it
  # resemble the file the developer is actually editing.
  defp write_temp_source(name, text) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "unex_deploy_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{safe_basename(name)}.u")
    File.write!(path, text)
    {path, fn -> File.rm_rf!(dir) end}
  end

  defp safe_basename(name) do
    case String.replace(name, ~r/[^A-Za-z0-9_-]/, "_") do
      "" -> "service"
      cleaned -> cleaned
    end
  end

  defp deploy_opts(params) do
    case params["capture_source"] do
      flag when is_boolean(flag) -> [capture_source: flag]
      _ -> []
    end
  end
end
