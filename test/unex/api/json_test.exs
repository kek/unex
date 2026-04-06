defmodule Unex.API.JsonTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Json

  describe "send_json/3" do
    test "sets status, content-type header, and encodes body" do
      conn =
        conn(:get, "/test")
        |> Json.send_json(200, %{hello: "world"})

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      assert Jason.decode!(conn.resp_body) == %{"hello" => "world"}
    end

    test "works with different status codes" do
      conn =
        conn(:get, "/test")
        |> Json.send_json(201, %{created: true})

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body) == %{"created" => true}
    end
  end

  describe "read_json/1" do
    test "returns {:ok, params} when body has been parsed" do
      conn =
        conn(:post, "/test", Jason.encode!(%{"name" => "testdb"}))
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(
          Plug.Parsers.init(parsers: [:json], json_decoder: Jason)
        )

      assert {:ok, %{"name" => "testdb"}} = Json.read_json(conn)
    end

    test "returns {:error, :not_parsed} when body_params is Unfetched" do
      conn = conn(:post, "/test", "some body")
      assert {:error, :not_parsed} = Json.read_json(conn)
    end
  end
end
