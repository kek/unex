defmodule Unex.Dispatcher do
  @moduledoc """
  Long-running wrapper around `ucm run.compiled <Dispatcher.uc>`.

  Instead of spawning UCM for every service call, a single dispatcher process
  stays alive and evaluates serialized `Value` thunks that arrive over a
  **localhost TCP socket**. Using a socket (instead of the subprocess's
  stdin/stdout) keeps those handles free for user service code, which may
  legitimately `printLine` or read stdin without corrupting the protocol.

  ## Startup

    1. Elixir listens on `127.0.0.1:0` (ephemeral port).
    2. Elixir spawns UCM as a `Port`, passing the listener's port as
       `UNEX_DISPATCHER_PORT` in the environment.
    3. The Unison program reads the env var, calls `Socket.client` back to
       127.0.0.1, and enters the request loop.
    4. Elixir accepts the one incoming connection.

  ## Wire protocol

  Both directions use length-prefixed frames: `<<len::unsigned-big-64, body::binary>>`.

    * Request body: `Value.serialize_v4` bytes of a thunk `'{IO, Exception} Text`.
    * Response body: 1-byte status tag + payload.
      - `0x00` — OK, UTF-8 result text.
      - `0xFF` — error, UTF-8 message.

  The UCM subprocess's stdout/stderr are captured and logged (tagged with
  `[dispatcher/stdout]`), but they are not part of the protocol.

  ## Supervision

  Added to `Unex.Application`'s tree only when `dispatcher.uc` exists on disk.
  Run `mix unex.compile_dispatcher` to produce it.
  """

  use GenServer
  require Logger

  @default_timeout 60_000
  @accept_timeout 10_000

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Evaluate a serialized `Value` thunk. `value_bytes` is the output of
  `Value.serialize_v4` applied to a `'{IO, Exception} Text` thunk.

  Returns `{:ok, result_text}` or `{:error, reason}`.
  """
  def eval(server \\ __MODULE__, value_bytes, timeout \\ @default_timeout) do
    GenServer.call(server, {:eval, value_bytes, timeout}, timeout + 5_000)
  end

  @doc "Returns `true` if the dispatcher's subprocess and socket are connected."
  def running?(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> false
      pid -> GenServer.call(pid, :running?)
    end
  end

  # --------------------------------------------------------------------------
  # GenServer callbacks
  # --------------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())

    cond do
      not File.exists?(path) ->
        Logger.warning(
          "Unex.Dispatcher: #{path} missing — not starting. " <>
            "Run `mix unex.compile_dispatcher` to build it."
        )

        :ignore

      match?({:error, _}, Unex.UCM.find()) ->
        Logger.error("Unex.Dispatcher: UCM not found on PATH")
        :ignore

      true ->
        start(path)
    end
  end

  defp start(path) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0,
        ip: {127, 0, 0, 1},
        mode: :binary,
        active: false,
        reuseaddr: true
      )

    {:ok, {_ip, port}} = :inet.sockname(listen_socket)

    {:ok, ucm} = Unex.UCM.find()

    env = [
      {~c"UNEX_URL",
       String.to_charlist("http://localhost:#{Application.get_env(:unex, :api_port, 4040)}")},
      {~c"UNEX_SECRET", String.to_charlist(Application.get_env(:unex, :api_secret, ""))},
      {~c"UNEX_DISPATCHER_PORT", String.to_charlist(Integer.to_string(port))}
    ]

    port_handle =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["run.compiled", path]},
        {:env, env}
      ])

    case :gen_tcp.accept(listen_socket, @accept_timeout) do
      {:ok, client} ->
        :ok = :inet.setopts(client, active: true)

        Logger.info("Unex.Dispatcher: started, path=#{path}, protocol on 127.0.0.1:#{port}")

        {:ok,
         %{
           path: path,
           listen: listen_socket,
           client: client,
           port: port_handle,
           queue: :queue.new(),
           buf: <<>>,
           stdout_buf: <<>>
         }}

      {:error, reason} ->
        Logger.error(
          "Unex.Dispatcher: accept timed out (#{inspect(reason)}). " <>
            "Check that dispatcher.uc is compatible with this base."
        )

        safe_close(listen_socket)
        Port.close(port_handle)
        {:stop, {:accept_failed, reason}}
    end
  end

  @impl true
  def handle_call(:running?, _from, state),
    do: {:reply, state.client != nil, state}

  def handle_call({:eval, bytes, _timeout}, from, state) do
    frame = <<byte_size(bytes)::unsigned-big-integer-size(64), bytes::binary>>
    :ok = :gen_tcp.send(state.client, frame)
    {:noreply, %{state | queue: :queue.in(from, state.queue)}}
  end

  @impl true
  def handle_info({:tcp, sock, data}, %{client: sock} = state) do
    {state, frames} = drain_frames(%{state | buf: state.buf <> data}, [])
    state = Enum.reduce(frames, state, &reply_frame/2)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, sock}, %{client: sock} = state) do
    Logger.error("Unex.Dispatcher: protocol socket closed")
    fail_queued(state, {:error, :socket_closed})
    {:stop, :socket_closed, %{state | client: nil}}
  end

  def handle_info({:tcp_error, sock, reason}, %{client: sock} = state) do
    Logger.error("Unex.Dispatcher: protocol socket error: #{inspect(reason)}")
    fail_queued(state, {:error, {:socket_error, reason}})
    {:stop, {:socket_error, reason}, %{state | client: nil}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # UCM subprocess stdout/stderr. Between a request and its response it's
    # the service program's printLine/etc output — accumulate it and hand it
    # back as the result. When no request is in flight, just log it.
    if :queue.is_empty(state.queue) do
      data
      |> String.split("\n", trim: true)
      |> Enum.each(&Logger.debug("[dispatcher/stdout] #{&1}"))

      {:noreply, state}
    else
      {:noreply, %{state | stdout_buf: state.stdout_buf <> data}}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Unex.Dispatcher: subprocess exited with status #{code}")
    fail_queued(state, {:error, {:port_exit, code}})
    {:stop, {:port_exit, code}, %{state | port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    safe_close(state[:client])
    safe_close(state[:listen])
    if is_port(state[:port]), do: Port.close(state[:port])
    :ok
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp drain_frames(state, acc) do
    case state.buf do
      <<len::unsigned-big-integer-size(64), rest::binary>> when byte_size(rest) >= len ->
        <<body::binary-size(len), rest2::binary>> = rest
        drain_frames(%{state | buf: rest2}, [body | acc])

      _ ->
        {state, Enum.reverse(acc)}
    end
  end

  defp reply_frame(body, state) do
    {{:value, from}, q2} = :queue.out(state.queue)
    reply = decode_response(body, state.stdout_buf)
    GenServer.reply(from, reply)
    %{state | queue: q2, stdout_buf: <<>>}
  end

  # The dispatcher always sends an empty OK body; the service's real output is
  # whatever it wrote to stdout between our send and this response. Errors
  # come through as 0xFF with a UTF-8 message.
  defp decode_response(<<0x00, _empty::binary>>, stdout), do: {:ok, stdout}
  defp decode_response(<<0xFF, msg::binary>>, _stdout), do: {:error, msg}
  defp decode_response(bytes, _stdout), do: {:error, {:unknown_response, bytes}}

  defp fail_queued(state, reply) do
    Enum.each(:queue.to_list(state.queue), fn from ->
      GenServer.reply(from, reply)
    end)
  end

  defp safe_close(nil), do: :ok

  defp safe_close(sock) do
    try do
      :gen_tcp.close(sock)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp default_path do
    data_dir = Application.get_env(:unex, :data_dir, "data")
    Path.join(data_dir, "dispatcher.uc")
  end
end
