defmodule Unex.API.BytecodeApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router
  alias Unex.Cluster.HashCache

  @opts Router.init([])

  defp call(method, path, body \\ nil, content_type \\ "application/octet-stream") do
    secret = Application.get_env(:unex, :api_secret)

    conn =
      if body do
        conn(method, path, body)
        |> put_req_header("content-type", content_type)
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> Router.call(@opts)
  end

  test "PUT /bytecode/:hash stores bytes and returns 201 with hash" do
    bytes = "fake-bytecode-data-#{System.unique_integer()}"
    hash = "test#{System.unique_integer([:positive])}"

    conn = call(:put, "/bytecode/#{hash}", bytes)
    assert conn.status == 201

    body = Jason.decode!(conn.resp_body)
    assert body["hash"] == hash
  end

  test "GET /bytecode/:hash returns 200 with stored bytes" do
    bytes = "fake-bytecode-#{System.unique_integer()}"
    hash = "gettest#{System.unique_integer([:positive])}"
    HashCache.put(HashCache, hash, bytes)

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

  test "PUT /bytecode/:hash is idempotent" do
    bytes = "idempotent-data-#{System.unique_integer()}"
    hash = "idem#{System.unique_integer([:positive])}"

    conn1 = call(:put, "/bytecode/#{hash}", bytes)
    conn2 = call(:put, "/bytecode/#{hash}", bytes)
    assert conn1.status == 201
    assert conn2.status == 201
  end

  test "GET /bytecode/:hash works when hash stored without # prefix" do
    bytes = "normalize-test-#{System.unique_integer()}"
    # Store directly in cache without # prefix
    bare_hash = "normalize#{System.unique_integer([:positive])}"
    HashCache.put(HashCache, bare_hash, bytes)

    # Retrieve via URL — route will pass hash without #
    conn = call(:get, "/bytecode/#{bare_hash}")
    assert conn.status == 200
    assert conn.resp_body == bytes
  end
end
