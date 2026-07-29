defmodule Unex.Dashboard.BasicAuthUnconfiguredTest do
  @moduledoc """
  What a production node that never enabled the dashboard is left holding:
  `nil` credentials, because `Unex.Dashboard.Credentials` refuses to leave the
  compiled-in `admin`/`unex` pair in application config. Not async — it mutates
  application env, so it runs after the async suite.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Unex.Dashboard.BasicAuth

  setup do
    saved = {
      Application.get_env(:unex, :dashboard_username),
      Application.get_env(:unex, :dashboard_password)
    }

    on_exit(fn ->
      {user, pass} = saved
      Application.put_env(:unex, :dashboard_username, user)
      Application.put_env(:unex, :dashboard_password, pass)
    end)

    Application.put_env(:unex, :dashboard_username, nil)
    Application.put_env(:unex, :dashboard_password, nil)

    :ok
  end

  test "rejects the shipped default credentials when nothing is configured" do
    creds = Base.encode64("admin:unex")

    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Basic #{creds}")
      |> BasicAuth.call(BasicAuth.init([]))

    assert conn.status == 401
    assert conn.halted
  end

  test "rejects an empty credential pair when nothing is configured" do
    creds = Base.encode64(":")

    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Basic #{creds}")
      |> BasicAuth.call(BasicAuth.init([]))

    assert conn.status == 401
    assert conn.halted
  end
end
