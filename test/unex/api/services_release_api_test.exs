defmodule Unex.API.ServicesReleaseApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router

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

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  @moduletag timeout: 180_000

  test "POST /services/:name/release returns 200 with name and hash" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"release-test\""
    deploy_conn = call(:post, "/services/deploy", %{"name" => "relapi-svc", "source" => source})
    assert deploy_conn.status == 201
    hash = json_body(deploy_conn)["hash"]

    conn = call(:post, "/services/relapi-svc/release", %{"hash" => hash})
    assert conn.status == 200

    body = json_body(conn)
    assert body["name"] == "relapi-svc"
    assert body["hash"] == hash
  end

  test "POST /services/:name/release without hash returns 422" do
    conn = call(:post, "/services/bad-svc/release", %{})
    assert conn.status == 422
  end

  test "released service is callable" do
    source = "main : '{IO, Exception} ()\nmain = do printLine \"released-ok\""
    deploy_conn = call(:post, "/services/deploy", %{"name" => "callrel-svc", "source" => source})
    hash = json_body(deploy_conn)["hash"]

    call(:post, "/services/callrel-svc/release", %{"hash" => hash})

    conn = call(:post, "/services/callrel-svc/call")
    assert conn.status == 200
    assert json_body(conn)["stdout"] =~ "released-ok"
  end
end
