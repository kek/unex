defmodule Unex.API.ServicesDeployTest do
  @moduledoc """
  Covers `POST /services/:name/deploy` accepting a local `.u` file's text in a
  `source` field, alongside the original `project` field.

  These exercise the request-shape and cleanup behaviour, which needs neither
  UCM nor Unison Share. That a file deploy produces the *same root hash* as the
  Share deploy of the same code is asserted in
  `test/integration/deploy_local_file_test.exs`.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Unex.API.Router

  @moduletag timeout: 120_000

  @opts Router.init([])

  defp deploy(name, body) do
    conn(:post, "/services/#{name}/deploy", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{Application.get_env(:unex, :api_secret)}")
    |> Router.call(@opts)
  end

  defp error(conn), do: Jason.decode!(conn.resp_body)["error"]

  describe "request shape" do
    test "an entry with neither project nor source is 422, and says so" do
      conn = deploy("no-origin", %{"entry" => "mainCounter"})

      assert conn.status == 422
      assert error(conn) =~ "one of project or source"
    end

    test "a source with no entry point is 422" do
      conn = deploy("no-entry", %{"source" => "x = 1\n"})

      assert conn.status == 422
      assert error(conn) == "entry is required"
    end

    test "an empty body is 422" do
      conn = deploy("nothing", %{})

      assert conn.status == 422
      assert error(conn) == "entry is required"
    end
  end

  describe "an inline source reaches Unex.Runtime as a file" do
    # The entry point is rejected by `Unex.Runtime.validate_entry_point/1`, which
    # runs before UCM is ever located — so this drives the whole controller →
    # Services → Runtime path, including writing the temp `.u` file, without
    # needing UCM or a network.
    test "the deploy is attempted and fails on the entry point, not on the source" do
      conn = deploy("bad-entry", %{"entry" => "main counter", "source" => "x = 1\n"})

      assert conn.status == 500
      assert error(conn) =~ "invalid entry_point"
    end

    test "the temporary .u file is cleaned up even when the deploy fails" do
      before = temp_deploy_dirs()

      conn = deploy("cleanup", %{"entry" => "main counter", "source" => "x = 1\n"})
      assert conn.status == 500

      assert temp_deploy_dirs() == before,
             "deploy left temporary source directories behind: " <>
               inspect(temp_deploy_dirs() -- before)
    end
  end

  describe "the Share path is unchanged" do
    test "a project is still accepted and still reaches extraction" do
      # `!` is rejected by the project validation, which — like the entry-point
      # check — happens before UCM is located. A 500 here means the request was
      # accepted and handed on, which is all this asserts.
      conn = deploy("share-still-works", %{"entry" => "mainCounter", "project" => "@kek/x!"})

      assert conn.status == 500
      assert error(conn) =~ "invalid project"
    end
  end

  defp temp_deploy_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "unex_deploy_"))
    |> Enum.sort()
  end
end
