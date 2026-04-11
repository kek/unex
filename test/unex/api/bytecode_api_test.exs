defmodule Unex.API.BytecodeApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router
  alias Unex.Cluster.HashCache

  @opts Router.init([])

  defp call(method, path, body \\ nil) do
    secret = Application.get_env(:unex, :api_secret)

    conn =
      if body do
        conn(method, path, body)
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> Router.call(@opts)
  end

  defp hex_body(bytes) do
    Jason.encode!(%{data: Base.encode16(bytes)})
  end

  test "POST /bytecode stores bytes and returns 201 with server-computed hash" do
    bytes = "fake-bytecode-data-#{System.unique_integer()}"

    conn = call(:post, "/bytecode", hex_body(bytes))
    assert conn.status == 201

    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["hash"])
    assert byte_size(body["hash"]) > 0
  end

  test "POST /bytecode returns hash that can be used to GET the bytes" do
    bytes = "fake-bytecode-roundtrip-#{System.unique_integer()}"

    post_conn = call(:post, "/bytecode", hex_body(bytes))
    assert post_conn.status == 201

    %{"hash" => hash} = Jason.decode!(post_conn.resp_body)

    get_conn = call(:get, "/bytecode/#{hash}")
    assert get_conn.status == 200
    assert get_conn.resp_body == bytes
  end

  test "GET /bytecode/:hash returns 200 with stored bytes" do
    bytes = "fake-bytecode-#{System.unique_integer()}"
    hash = HashCache.put(HashCache, bytes)

    conn = call(:get, "/bytecode/#{hash}")
    assert conn.status == 200
    assert conn.resp_body == bytes
  end

  test "GET /bytecode/:hash returns 404 for unknown hash" do
    conn = call(:get, "/bytecode/nonexistent-hash-xyz")
    assert conn.status == 404

    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "not_found"
  end

  test "POST /bytecode is idempotent" do
    bytes = "idempotent-data-#{System.unique_integer()}"

    conn1 = call(:post, "/bytecode", hex_body(bytes))
    conn2 = call(:post, "/bytecode", hex_body(bytes))
    assert conn1.status == 201
    assert conn2.status == 201

    body1 = Jason.decode!(conn1.resp_body)
    body2 = Jason.decode!(conn2.resp_body)
    assert body1["hash"] == body2["hash"]
  end

  test "POST /bytecode with invalid hex returns 400" do
    conn = call(:post, "/bytecode", Jason.encode!(%{data: "not-valid-hex!!!"}))
    assert conn.status == 400
  end

  test "POST /bytecode with missing data field returns 400" do
    conn = call(:post, "/bytecode", Jason.encode!(%{wrong: "field"}))
    assert conn.status == 400
  end
end
