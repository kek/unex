defmodule Unex.Dispatcher.Pool do
  @moduledoc """
  NimblePool-backed pool of `Unex.Dispatcher` workers.

  Each pool slot holds one persistent UCM subprocess and its TCP protocol
  socket. Concurrent service calls are distributed across workers; when all
  workers are busy, callers queue inside NimblePool until a worker is free or
  the timeout elapses.

  Pool size is controlled by the `:dispatcher_pool_size` application config key
  (env: `UNEX_DISPATCHER_POOL_SIZE`). Default: 4.
  """

  @behaviour NimblePool

  require Logger

  @default_timeout 60_000

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  def start_link(opts \\ []) do
    pool_size =
      Keyword.get(opts, :pool_size, Application.get_env(:unex, :dispatcher_pool_size, 4))

    NimblePool.start_link(
      worker: {__MODULE__, []},
      pool_size: pool_size,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Evaluate a serialized `Value` thunk using a free pool worker.

  Blocks until a worker is available or `timeout` ms elapse.
  Returns `{:ok, result_text}` or `{:error, reason}`.
  """
  def eval(bytes, timeout \\ @default_timeout) do
    try do
      NimblePool.checkout!(
        __MODULE__,
        :checkout,
        fn _from, pid ->
          result = Unex.Dispatcher.eval(pid, bytes, timeout)
          {result, :ok}
        end,
        timeout
      )
    catch
      :exit, {:timeout, {NimblePool, :checkout, _}} -> {:error, :pool_timeout}
      :exit, reason -> {:error, {:worker_exit, reason}}
    end
  end

  @doc "Returns `true` if the pool process is registered and alive."
  def available? do
    Process.whereis(__MODULE__) != nil
  end

  # --------------------------------------------------------------------------
  # NimblePool.Worker callbacks
  # --------------------------------------------------------------------------

  @impl NimblePool
  def init_worker(pool_state) do
    {:ok, pid} = Unex.Dispatcher.start_link(name: nil)
    {:ok, pid, pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, pid, pool_state) do
    if Process.alive?(pid) do
      {:ok, pid, pid, pool_state}
    else
      {:remove, :not_running, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin(:ok, _from, pid, pool_state) do
    {:ok, pid, pool_state}
  end

  def handle_checkin(_other, _from, _pid, pool_state) do
    {:remove, :unexpected_checkin_state, pool_state}
  end

  @impl NimblePool
  def terminate_worker(_reason, pid, pool_state) do
    if Process.alive?(pid) do
      Task.start(fn -> GenServer.stop(pid, :normal, 5_000) end)
    end

    {:ok, pool_state}
  end
end
