defmodule Unex.Integration.ServiceLifecycleTest do
  @moduledoc """
  Full lifecycle integration test:

    1. Pull a real Unison project (`@kek/counter`) from Unison Share.
    2. Extract the entry point into serialized Value + transitive Code bytes.
    3. Register the service in the cluster.
    4. Fetch `/services/counter/web` as a plain HTTP client.
    5. Assert the rendered HTML comes back through the dispatcher.

  The test requires:
    - `ucm` on PATH
    - Network access to Unison Share (for the initial pull)
    - `data/dispatcher.uc` already compiled — if missing, the test will
      build it via `mix unex.compile_dispatcher`.

  One UCM subprocess handles every call; we verify that too.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  @test_port 4044
  @dispatcher_uc "data/dispatcher.uc"

  setup_all do
    unless File.exists?(@dispatcher_uc) do
      IO.puts("Building #{@dispatcher_uc} — this takes a minute...")
      Mix.Task.run("unex.compile_dispatcher", [])
    end

    mnesia_dir =
      Path.join(
        System.tmp_dir!(),
        "unex_lifecycle_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(mnesia_dir)
    Unex.Storage.Schema.init(mnesia_dir)

    # Point dispatcher's UNEX_URL env at the test port before starting it.
    old_api_port = Application.get_env(:unex, :api_port)
    Application.put_env(:unex, :api_port, @test_port)

    {:ok, bandit_pid} = Bandit.start_link(plug: Unex.API.Router, port: @test_port)
    {:ok, dispatcher_pid} = Unex.Dispatcher.start_link()

    on_exit(fn ->
      if Process.alive?(dispatcher_pid), do: GenServer.stop(dispatcher_pid, :normal, 5_000)
      Process.exit(bandit_pid, :normal)
      :mnesia.stop()
      File.rm_rf!(mnesia_dir)

      if old_api_port do
        Application.put_env(:unex, :api_port, old_api_port)
      else
        Application.delete_env(:unex, :api_port)
      end
    end)

    {:ok, port: @test_port}
  end

  test "deploy @kek/counter from Unison Share, call /web, get rendered HTML",
       %{port: port} do
    secret = Application.get_env(:unex, :api_secret)

    # ---- Deploy ----
    {deploy_status, _, deploy_body} =
      http_request(port,
        method: "POST",
        path: "/services/counter/deploy",
        headers: [
          {"authorization", "Bearer #{secret}"},
          {"content-type", "application/json"}
        ],
        body: ~s({"project":"@kek/counter","entry":"mainCounter"}),
        timeout: 300_000
      )

    assert deploy_status == 200,
           "deploy failed (status=#{deploy_status}): #{deploy_body}"

    deploy_json = Jason.decode!(deploy_body)
    assert deploy_json["name"] == "counter"
    assert is_binary(deploy_json["hash"])
    assert String.length(deploy_json["hash"]) == 64

    # ---- Fetch /web ----
    {web_status, web_headers, web_body} =
      http_request(port,
        method: "GET",
        path: "/services/counter/web",
        headers: [{"authorization", "Bearer #{secret}"}],
        timeout: 120_000
      )

    assert web_status == 200,
           "web fetch failed (status=#{web_status}): #{web_body}"

    assert web_body =~ ~r|<!DOCTYPE html>|i
    assert web_body =~ ~r|<h1>Visitor #\d+</h1>|
    assert web_body =~ ~r|</body></html>|

    assert Enum.any?(web_headers, fn {k, v} ->
             String.downcase(k) == "content-type" and String.contains?(v, "text/html")
           end),
           "expected text/html content-type, got: #{inspect(web_headers)}"

    # ---- Fetch /web again, verify counter incremented ----
    first_n =
      Regex.run(~r|<h1>Visitor #(\d+)</h1>|, web_body)
      |> List.last()
      |> String.to_integer()

    {200, _, web_body_2} =
      http_request(port,
        method: "GET",
        path: "/services/counter/web",
        headers: [{"authorization", "Bearer #{secret}"}],
        timeout: 120_000
      )

    second_n =
      Regex.run(~r|<h1>Visitor #(\d+)</h1>|, web_body_2)
      |> List.last()
      |> String.to_integer()

    assert second_n == first_n + 1,
           "expected counter to advance by 1 on second call (was #{first_n}, got #{second_n})"

    # ---- Verify only one UCM subprocess is running ----
    {ps_out, 0} =
      System.cmd("pgrep", ["-f", "ucm run.compiled"], stderr_to_stdout: true)

    ucm_count = ps_out |> String.split("\n", trim: true) |> length()

    assert ucm_count == 1,
           "expected exactly one UCM subprocess for the whole session, found #{ucm_count}"
  end

  # Minimal dependency-free HTTP/1.1 client over :gen_tcp. Small request bodies
  # only; reads until the server closes the connection (Bandit honors
  # Connection: close). Avoids the :inets module-loading dance in test envs.
  defp http_request(port, opts) do
    method = Keyword.fetch!(opts, :method)
    path = Keyword.fetch!(opts, :path)
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")
    timeout = Keyword.get(opts, :timeout, 30_000)

    base_headers = [
      {"host", "127.0.0.1:#{port}"},
      {"connection", "close"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    all_headers = base_headers ++ headers

    header_lines =
      all_headers
      |> Enum.map(fn {k, v} -> "#{k}: #{v}\r\n" end)
      |> IO.iodata_to_binary()

    request =
      IO.iodata_to_binary([
        "#{method} #{path} HTTP/1.1\r\n",
        header_lines,
        "\r\n",
        body
      ])

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    :ok = :gen_tcp.send(sock, request)
    raw = recv_all(sock, timeout, <<>>)
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock, timeout, acc) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} -> recv_all(sock, timeout, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> raise "tcp recv failed: #{inspect(reason)}"
    end
  end

  defp parse_response(raw) do
    [head, body] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    [_http, code, _phrase] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.map(header_lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {k, v}
      end)

    {String.to_integer(code), headers, body}
  end
end
