defmodule Unex.API.ConfigController do
  @moduledoc false
  alias Unex.API.Json
  alias Unex.Abilities.Config

  def set(conn, env, key) do
    {:ok, %{"value" => value}} = Json.read_json(conn)
    :ok = Config.set(env, key, value)
    Json.send_json(conn, 200, %{env: env, key: key})
  end

  def get(conn, env, key) do
    case Config.get(env, key) do
      {:ok, value} -> Json.send_json(conn, 200, %{env: env, key: key, value: value})
      :not_found -> Json.send_json(conn, 404, %{error: "not_found"})
    end
  end

  def list(conn, env) do
    keys = Config.list(env)
    Json.send_json(conn, 200, %{env: env, keys: keys})
  end
end
