defmodule Unex.API.BlobsController do
  @moduledoc false
  alias Unex.API.Json
  alias Unex.Abilities.Blobs

  defp blobs_dir do
    Application.get_env(:unex, :blobs_dir, Path.join(System.tmp_dir!(), "unex_blobs"))
  end

  def write(conn, db, key) do
    {:ok, %{"data" => b64_data}} = Json.read_json(conn)
    data = Base.decode64!(b64_data)
    :ok = Blobs.write(blobs_dir(), db, key, data)
    Json.send_json(conn, 200, %{db: db, key: key})
  end

  def read(conn, db, key) do
    case Blobs.read(blobs_dir(), db, key) do
      {:ok, data} -> Json.send_json(conn, 200, %{db: db, key: key, data: Base.encode64(data)})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  def list(conn, db) do
    {:ok, %{"prefix" => prefix}} = Json.read_json(conn)
    keys = Blobs.list(blobs_dir(), db, prefix)
    Json.send_json(conn, 200, %{db: db, keys: keys})
  end
end
