defmodule Uniops.API.AbilitiesAPITest do
  use ExUnit.Case, async: false
  use Plug.Test

  setup_all do
    dir = Path.join(System.tmp_dir!(), "uniops_abilities_api_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Uniops.Storage.Schema.init(dir)
    Application.put_env(:uniops, :blobs_dir, Path.join(dir, "blobs"))

    case Process.whereis(Uniops.Abilities.Scratch) do
      nil -> {:ok, _} = Uniops.Abilities.Scratch.start_link([])
      _ -> :ok
    end

    case Process.whereis(Uniops.Abilities.Log) do
      nil -> {:ok, _} = Uniops.Abilities.Log.start_link([])
      _ -> :ok
    end

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)
    :ok
  end

  defp call(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> Uniops.API.Router.call(Uniops.API.Router.init([]))
  end

  # --- Config ---

  describe "Config API" do
    test "set and get a secret" do
      conn = conn(:post, "/config/prod/api_key",
        Jason.encode!(%{value: "sk-123"})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/config/prod/api_key") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["value"] == "sk-123"
    end

    test "get missing returns 404" do
      conn = conn(:get, "/config/prod/nope") |> call()
      assert conn.status == 404
    end

    test "list keys" do
      conn(:post, "/config/listenv/k1", Jason.encode!(%{value: "v1"})) |> call()
      conn(:post, "/config/listenv/k2", Jason.encode!(%{value: "v2"})) |> call()
      conn = conn(:get, "/config/listenv") |> call()
      assert conn.status == 200
      keys = Jason.decode!(conn.resp_body)["keys"]
      assert "k1" in keys
      assert "k2" in keys
    end
  end

  # --- Blobs ---

  describe "Blobs API" do
    test "write and read a blob" do
      conn = conn(:post, "/blobs/mydb/files/test.txt",
        Jason.encode!(%{data: Base.encode64("hello blob")})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/blobs/mydb/files/test.txt") |> call()
      assert conn.status == 200
      assert Base.decode64!(Jason.decode!(conn.resp_body)["data"]) == "hello blob"
    end

    test "read missing returns 404" do
      conn = conn(:get, "/blobs/mydb/nope") |> call()
      assert conn.status == 404
    end

    test "list by prefix" do
      conn(:post, "/blobs/mydb/imgs/a.jpg", Jason.encode!(%{data: Base.encode64("a")})) |> call()
      conn(:post, "/blobs/mydb/imgs/b.jpg", Jason.encode!(%{data: Base.encode64("b")})) |> call()
      conn = conn(:post, "/blobs/mydb/list", Jason.encode!(%{prefix: "imgs/"})) |> call()
      assert conn.status == 200
      keys = Jason.decode!(conn.resp_body)["keys"]
      assert "imgs/a.jpg" in keys
    end
  end

  # --- Scratch ---

  describe "Scratch API" do
    test "put and get" do
      conn = conn(:post, "/scratch/mykey",
        Jason.encode!(%{value: "cached"})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/scratch/mykey") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["value"] == "cached"
    end

    test "get missing returns 404" do
      conn = conn(:get, "/scratch/nope") |> call()
      assert conn.status == 404
    end
  end

  # --- Log ---

  describe "Log API" do
    test "append and get recent" do
      conn = conn(:post, "/log",
        Jason.encode!(%{level: "info", message: "test log", metadata: %{svc: "test"}})) |> call()
      assert conn.status == 200

      conn = conn(:get, "/log/recent/10") |> call()
      assert conn.status == 200
      entries = Jason.decode!(conn.resp_body)["entries"]
      assert length(entries) >= 1
      assert hd(entries)["message"] == "test log"
    end
  end
end
