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

  test "POST /bytecode/:hash stores bytes and returns 201 with hash" do
    bytes = "fake-bytecode-data-#{System.unique_integer()}"
    hash = "test#{System.unique_integer([:positive])}"

    conn = call(:post, "/bytecode/#{hash}", hex_body(bytes))
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

  test "POST /bytecode/:hash is idempotent" do
    bytes = "idempotent-data-#{System.unique_integer()}"
    hash = "idem#{System.unique_integer([:positive])}"

    conn1 = call(:post, "/bytecode/#{hash}", hex_body(bytes))
    conn2 = call(:post, "/bytecode/#{hash}", hex_body(bytes))
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

  test "POST /bytecode/:hash with invalid hex returns 400" do
    conn = call(:post, "/bytecode/testhash", Jason.encode!(%{data: "not-valid-hex!!!"}))
    assert conn.status == 400
  end

  test "POST /bytecode/:hash with missing data field returns 400" do
    conn = call(:post, "/bytecode/testhash", Jason.encode!(%{wrong: "field"}))
    assert conn.status == 400
  end

  test "POST /bytecode/:hash with # prefix normalizes hash in response" do
    bytes = "normalize_test_bytes"
    hex = Base.encode16(bytes)

    # %23 is URL-encoded '#'; Plug decodes it to '#' before routing,
    # and normalize_hash/1 strips the leading '#' before storage.
    conn = call(:post, "/bytecode/%23abc999", Jason.encode!(%{data: hex}))
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["hash"] == "abc999"
  end
end
