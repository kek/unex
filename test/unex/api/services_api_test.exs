defmodule Unex.API.ServicesApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router
  alias Unex.Cluster.HashCache

  @moduletag timeout: 300_000

  @opts Router.init([])

  defp call(method, path, body \\ nil) do
    secret = Application.get_env(:unex, :api_secret)

    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> Router.call(@opts)
  end

  defp json_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  test "POST /services/:name/release returns 200 with name and hash" do
    hash = HashCache.put("api_release_bytes_#{System.unique_integer()}")

    conn = call(:post, "/services/api-svc/release", %{"hash" => hash})
    assert conn.status == 200

    body = json_body(conn)
    assert body["name"] == "api-svc"
    assert body["hash"] == hash
  end

  test "POST /services/unknown/call returns 404" do
    conn = call(:post, "/services/unknown-xyz/call")
    assert conn.status == 404
    assert json_body(conn)["error"] == "not_found"
  end

  test "GET /services returns 200 with list" do
    hash = HashCache.put("list_api_bytes_#{System.unique_integer()}")
    call(:post, "/services/list-api-svc/release", %{"hash" => hash})

    conn = call(:get, "/services")
    assert conn.status == 200

    body = json_body(conn)
    names = Enum.map(body["services"], & &1["name"])
    assert "list-api-svc" in names
  end

  test "DELETE /services/:name returns 200, then call returns 404" do
    hash = HashCache.put("del_api_bytes_#{System.unique_integer()}")
    call(:post, "/services/del-svc/release", %{"hash" => hash})

    conn = call(:delete, "/services/del-svc")
    assert conn.status == 200

    conn = call(:post, "/services/del-svc/call")
    assert conn.status == 404
  end
end
