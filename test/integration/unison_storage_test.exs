defmodule Unex.Integration.UnisonStorageTest do
  @moduledoc """
  End-to-end test: a Unison program makes HTTP calls to our storage API,
  writes data, reads it back, and prints the result. We verify via stdout.
  """
  use ExUnit.Case, async: false

  setup_all do
    # 1. Init Mnesia for storage
    mnesia_dir =
      Path.join(
        System.tmp_dir!(),
        "unex_unison_storage_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(mnesia_dir)
    Unex.Storage.Schema.init(mnesia_dir)

    # 2. Start Bandit on an OS-assigned ephemeral port bound to localhost.
    # Hard-coded ports collided with a running dev node that held
    # 127.0.0.1:4041 for the dashboard, silently routing test requests
    # there.
    {:ok, bandit_pid} =
      Bandit.start_link(plug: Unex.API.Router, port: 0, ip: {127, 0, 0, 1})

    {:ok, {_addr, port}} = ThousandIsland.listener_info(bandit_pid)

    on_exit(fn ->
      Process.exit(bandit_pid, :normal)
      :mnesia.stop()
      File.rm_rf!(mnesia_dir)
    end)

    {:ok, port: port}
  end

  @tag timeout: 300_000
  test "Unison program hits /health endpoint", %{port: port} do
    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    main : '{IO, Exception} ()
    main = do
      Threads.run do Http.run do
        resp = Http.get (URI.parse "http://127.0.0.1:#{port}/health")
        printLine (bodyText resp)
    """

    assert {:ok, result} = Unex.eval(source, timeout: 120_000)
    stdout = Unex.UCM.Output.strip_ansi(result.stdout)
    assert stdout =~ "ok"
  end

  @tag timeout: 300_000
  test "Unison program writes and reads from storage API", %{port: port} do
    secret = Application.get_env(:unex, :api_secret)

    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    authHeader : HttpRequest -> HttpRequest
    authHeader req = HttpRequest.addHeader "Authorization" "Bearer #{secret}" req

    main : '{IO, Exception} ()
    main = do
      base = "http://127.0.0.1:#{port}"

      Threads.run do Http.run do
        -- Step 1: create database
        createDbReq =
          authHeader
            (HttpRequest.addHeader "Content-Type" "application/json"
              (HttpRequest.post
                (URI.parse (base ++ "/databases"))
                (Body.fromText "{\\"name\\":\\"unisondb\\"}")))
        _ = Http.request createDbReq

        -- Step 2: ensure table
        ensureTableReq =
          authHeader
            (HttpRequest.addHeader "Content-Type" "application/json"
              (HttpRequest.post
                (URI.parse (base ++ "/databases/unisondb/tables/items"))
                Body.empty))
        _ = Http.request ensureTableReq

        -- Step 3: write key/value
        writeReq =
          authHeader
            (HttpRequest.addHeader "Content-Type" "application/json"
              (HttpRequest.post
                (URI.parse (base ++ "/databases/unisondb/tables/items/write"))
                (Body.fromText "{\\"key\\":\\"hello\\",\\"value\\":\\"world\\"}")))
        _ = Http.request writeReq

        -- Step 4: read back
        readResp = Http.request (authHeader (HttpRequest.get (URI.parse (base ++ "/databases/unisondb/tables/items/read/hello"))))
        body = bodyText readResp
        printLine body
    """

    assert {:ok, result} = Unex.eval(source, timeout: 120_000)
    stdout = Unex.UCM.Output.strip_ansi(result.stdout)

    # The response body should contain the value we wrote
    assert stdout =~ "world"
    assert stdout =~ "hello"
  end
end
