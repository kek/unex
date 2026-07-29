defmodule Unex.Dashboard.BasicAuthTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Unex.Dashboard.BasicAuth

  defp call(conn, opts), do: BasicAuth.call(conn, BasicAuth.init(opts))

  test "halts with 401 when no Authorization header" do
    conn = conn(:get, "/") |> call(username: "u", password: "p")
    assert conn.status == 401
    assert conn.halted

    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
             ~s(Basic realm="Unex Dashboard")
           ]
  end

  test "halts with 401 on bad credentials" do
    creds = Base.encode64("u:wrong")

    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Basic #{creds}")
      |> call(username: "u", password: "p")

    assert conn.status == 401
    assert conn.halted
  end

  test "passes through on correct credentials" do
    creds = Base.encode64("u:p")

    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Basic #{creds}")
      |> call(username: "u", password: "p")

    refute conn.halted
  end

  test "fails closed on a blank configured password" do
    creds = Base.encode64("u:")

    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Basic #{creds}")
      |> call(username: "u", password: "")

    assert conn.status == 401
    assert conn.halted
  end

  test "rejects right-length-but-wrong-value password" do
    creds = Base.encode64("u:q")

    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Basic #{creds}")
      |> call(username: "u", password: "p")

    assert conn.status == 401
  end
end
