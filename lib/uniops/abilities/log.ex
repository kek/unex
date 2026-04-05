defmodule Uniops.Abilities.Log do
  @moduledoc """
  Structured logging with an ETS ring buffer.
  Stores the most recent N entries, evicting oldest when full.
  Also forwards to Elixir's Logger.
  """

  use GenServer

  require Logger

  defmodule Entry do
    @moduledoc false
    defstruct [:id, :level, :message, :metadata, :timestamp]
  end

  @default_max 1000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    max = Keyword.get(opts, :max_entries, @default_max)
    GenServer.start_link(__MODULE__, %{name: name, max: max}, name: name)
  end

  def append(server \\ __MODULE__, level, message, metadata \\ %{}) do
    GenServer.call(server, {:append, level, message, metadata})
  end

  def info(server \\ __MODULE__, message, metadata \\ %{}), do: append(server, :info, message, metadata)
  def error(server \\ __MODULE__, message, metadata \\ %{}), do: append(server, :error, message, metadata)
  def warn(server \\ __MODULE__, message, metadata \\ %{}), do: append(server, :warn, message, metadata)

  @doc "Returns the most recent `n` entries, newest first."
  def recent(server \\ __MODULE__, n) do
    GenServer.call(server, {:recent, n})
  end

  @impl true
  def init(%{name: name, max: max}) do
    table = :ets.new(name, [:ordered_set, :public])
    {:ok, %{table: table, max: max, counter: 0}}
  end

  @impl true
  def handle_call({:append, level, message, metadata}, _from, state) do
    counter = state.counter + 1

    entry = %Entry{
      id: counter,
      level: level,
      message: message,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(state.table, {counter, entry})

    # Forward to Logger
    case level do
      :info -> Logger.info(message, Map.to_list(metadata))
      :error -> Logger.error(message, Map.to_list(metadata))
      :warn -> Logger.warning(message, Map.to_list(metadata))
      _ -> Logger.debug(message, Map.to_list(metadata))
    end

    # Evict oldest if over max
    new_state =
      if counter > state.max do
        evict_key = counter - state.max
        :ets.delete(state.table, evict_key)
        %{state | counter: counter}
      else
        %{state | counter: counter}
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:recent, n}, _from, state) do
    all = :ets.tab2list(state.table)

    entries =
      all
      |> Enum.sort_by(fn {id, _} -> id end, :desc)
      |> Enum.take(n)
      |> Enum.map(fn {_, entry} -> entry end)

    {:reply, entries, state}
  end
end
