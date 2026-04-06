defmodule Unex.API.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router

  @opts Router.init([])

  setup_all do
    dir = Path.join(System.tmp_dir!(), "unex_router_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Unex.Storage.Schema.init(dir)

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp call(method, path, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    Router.call(conn, @opts)
  end

  defp json_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  test "GET /health returns 200" do
    conn = call(:get, "/health")
    assert conn.status == 200
    assert json_body(conn) == %{"status" => "ok"}
  end

  test "POST /databases + GET /databases" do
    conn = call(:post, "/databases", %{"name" => "router_test_db"})
    assert conn.status == 201
    assert json_body(conn)["name"] == "router_test_db"

    conn = call(:get, "/databases")
    assert conn.status == 200
    assert "router_test_db" in json_body(conn)["databases"]
  end

  test "ordered table CRUD cycle" do
    db = "crud_db"
    table = "items"

    call(:post, "/databases", %{"name" => db})

    # ensure table
    conn = call(:post, "/databases/#{db}/tables/#{table}")
    assert conn.status == 201

    # write 3 keys
    for {k, v} <- [{"a", "alpha"}, {"b", "beta"}, {"c", "gamma"}] do
      conn = call(:post, "/databases/#{db}/tables/#{table}/write", %{"key" => k, "value" => v})
      assert conn.status == 200
    end

    # read one
    conn = call(:get, "/databases/#{db}/tables/#{table}/read/b")
    assert conn.status == 200
    assert json_body(conn) == %{"key" => "b", "value" => "beta"}

    # scan range
    conn = call(:post, "/databases/#{db}/tables/#{table}/scan", %{"from" => "a", "to" => "b"})
    assert conn.status == 200
    results = json_body(conn)["results"]
    assert length(results) == 2
    assert Enum.at(results, 0) == %{"key" => "a", "value" => "alpha"}
    assert Enum.at(results, 1) == %{"key" => "b", "value" => "beta"}

    # delete one
    conn = call(:delete, "/databases/#{db}/tables/#{table}/delete/b")
    assert conn.status == 200

    # verify deleted
    conn = call(:get, "/databases/#{db}/tables/#{table}/read/b")
    assert conn.status == 404
  end

  test "cell write + read, missing cell returns 404" do
    db = "cell_db"
    call(:post, "/databases", %{"name" => db})

    # write cell
    conn = call(:post, "/databases/#{db}/cells/counter/write", %{"value" => 42})
    assert conn.status == 200
    assert json_body(conn) == %{"name" => "counter", "value" => 42}

    # read cell
    conn = call(:get, "/databases/#{db}/cells/counter/read")
    assert conn.status == 200
    assert json_body(conn) == %{"name" => "counter", "value" => 42}

    # missing cell returns 404
    conn = call(:get, "/databases/#{db}/cells/nonexistent/read")
    assert conn.status == 404
  end

  test "transaction: batch writes and verify" do
    db = "tx_db"
    table = "tx_items"

    call(:post, "/databases", %{"name" => db})
    call(:post, "/databases/#{db}/tables/#{table}")

    ops = [
      %{"op" => "write_table", "table" => table, "key" => "x", "value" => "ex"},
      %{"op" => "write_table", "table" => table, "key" => "y", "value" => "why"},
      %{"op" => "write_cell", "name" => "flag", "value" => true}
    ]

    conn = call(:post, "/databases/#{db}/tx", %{"operations" => ops})
    assert conn.status == 200
    assert json_body(conn) == %{"status" => "committed"}

    # verify table writes
    conn = call(:get, "/databases/#{db}/tables/#{table}/read/x")
    assert conn.status == 200
    assert json_body(conn)["value"] == "ex"

    conn = call(:get, "/databases/#{db}/tables/#{table}/read/y")
    assert conn.status == 200
    assert json_body(conn)["value"] == "why"

    # verify cell write
    conn = call(:get, "/databases/#{db}/cells/flag/read")
    assert conn.status == 200
    assert json_body(conn)["value"] == true
  end

  test "unknown route returns 404" do
    conn = call(:get, "/nonexistent")
    assert conn.status == 404
  end
end
