defmodule Unex.API.ServicesApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router

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

  test "POST /services/deploy returns 201 with name and hash" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"api-hello\""

    conn = call(:post, "/services/deploy", %{"name" => "api-svc", "source" => source})
    assert conn.status == 201

    body = json_body(conn)
    assert body["name"] == "api-svc"
    assert is_binary(body["hash"])
    assert is_binary(body["node"])
  end

  test "POST /services/:name/call returns 200 with stdout" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"api-call-ok\""
    call(:post, "/services/deploy", %{"name" => "call-svc", "source" => source})

    conn = call(:post, "/services/call-svc/call")
    assert conn.status == 200

    body = json_body(conn)
    assert body["stdout"] =~ "api-call-ok"
  end

  test "POST /services/unknown/call returns 404" do
    conn = call(:post, "/services/unknown-xyz/call")
    assert conn.status == 404
    assert json_body(conn)["error"] == "not_found"
  end

  test "GET /services returns 200 with list" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"list-me\""
    call(:post, "/services/deploy", %{"name" => "list-api-svc", "source" => source})

    conn = call(:get, "/services")
    assert conn.status == 200

    body = json_body(conn)
    names = Enum.map(body["services"], & &1["name"])
    assert "list-api-svc" in names
  end

  test "DELETE /services/:name returns 200, then call returns 404" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"del-me\""
    call(:post, "/services/deploy", %{"name" => "del-svc", "source" => source})

    conn = call(:delete, "/services/del-svc")
    assert conn.status == 200

    conn = call(:post, "/services/del-svc/call")
    assert conn.status == 404
  end
end
