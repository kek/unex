defmodule Unex.Dispatcher do
  @moduledoc """
  Long-running Port wrapper around `ucm run.compiled <Dispatcher.uc>`.

  Instead of spawning UCM for every service call, a single dispatcher process
  stays alive and receives serialized `Value` thunks over its stdin. It
  evaluates them using Unison's reflection primitives (`Value.load`,
  `Code.cache_`) and writes results back over stdout. Missing code
  dependencies are fetched by the dispatcher itself via HTTP against this
  server's `GET /code/:termhash` endpoint.

  ## Wire protocol

  Both directions use length-prefixed frames: `<<len::unsigned-big-64, body::binary>>`.

    * Request body: raw bytes from `Value.serialize_v4` of a thunk
      `'{IO, Exception} Text`.
    * Response body: 1-byte status tag + payload.
      - `0x00` — OK, payload is UTF-8 result text.
      - `0xFF` — error, payload is UTF-8 error message.

  Stderr from the Unison program is logged but not parsed.

  ## Supervision

  Added to `Unex.Application`'s tree only when `dispatcher.uc` exists on disk
  at the configured path. Use `mix unex.compile_dispatcher` to produce it.
  """

  use GenServer
  require Logger

  @default_timeout 60_000

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

  @doc "Returns `true` if the dispatcher port is live."
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

    if File.exists?(path) do
      case Unex.UCM.find() do
        {:ok, ucm} ->
          env = env_charlist()

          port =
            Port.open({:spawn_executable, ucm}, [
              :binary,
              :exit_status,
              :use_stdio,
              {:args, ["run.compiled", path]},
              {:env, env}
            ])

          Logger.info("Unex.Dispatcher: started, path=#{path}")
          {:ok, %{port: port, path: path, queue: :queue.new(), buf: <<>>}}

        {:error, :not_found} ->
          Logger.error("Unex.Dispatcher: UCM not found on PATH")
          :ignore
      end
    else
      Logger.warning(
        "Unex.Dispatcher: #{path} missing — not starting. " <>
          "Run `mix unex.compile_dispatcher` to build it."
      )

      :ignore
    end
  end

  @impl true
  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}

  def handle_call({:eval, bytes, _timeout}, from, state) do
    frame = <<byte_size(bytes)::unsigned-big-integer-size(64), bytes::binary>>
    true = Port.command(state.port, frame)
    {:noreply, %{state | queue: :queue.in(from, state.queue)}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {state, frames} = drain_frames(%{state | buf: state.buf <> data}, [])
    state = Enum.reduce(frames, state, &reply_frame/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Unex.Dispatcher: port exited with status #{code}")

    Enum.each(:queue.to_list(state.queue), fn from ->
      GenServer.reply(from, {:error, {:port_exit, code}})
    end)

    {:stop, {:port_exit, code}, %{state | queue: :queue.new(), port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --------------------------------------------------------------------------
  # Private helpers
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
    GenServer.reply(from, decode_response(body))
    %{state | queue: q2}
  end

  defp decode_response(<<0x00, payload::binary>>), do: {:ok, payload}
  defp decode_response(<<0xFF, msg::binary>>), do: {:error, msg}
  defp decode_response(bytes), do: {:error, {:unknown_response, bytes}}

  defp default_path do
    data_dir = Application.get_env(:unex, :data_dir, "data")
    Path.join(data_dir, "dispatcher.uc")
  end

  defp env_charlist do
    port = Application.get_env(:unex, :api_port, 4040)
    secret = Application.get_env(:unex, :api_secret, "")

    [
      {~c"UNEX_URL", String.to_charlist("http://localhost:#{port}")},
      {~c"UNEX_SECRET", String.to_charlist(secret)}
    ]
  end
end
