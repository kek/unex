defmodule Unex.Abilities.Scratch do
  @moduledoc """
  Ephemeral in-memory cache, node-local. Backed by ETS.
  Data is lost on node restart — use for temporary/session state only.
  """

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  def put(server \\ __MODULE__, key, value) do
    GenServer.call(server, {:put, key, value})
  end

  def get(server \\ __MODULE__, key) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  def delete(server \\ __MODULE__, key) do
    GenServer.call(server, {:delete, key})
  end

  def list(server \\ __MODULE__) do
    table = GenServer.call(server, :table)
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @impl true
  def init(name) do
    table = :ets.new(name, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(state.table, {key, value})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, state) do
    {:reply, state.table, state}
  end
end
