defmodule Uniops.Services.Registry do
  @moduledoc """
  ETS-backed registry mapping service names to their bytecode hashes
  and deployment metadata. Supports cross-node resolution.
  """

  use GenServer

  defmodule Entry do
    @moduledoc "A registered service entry."
    defstruct [:name, :hash, :node, :deployed_at]

    @type t :: %__MODULE__{
            name: String.t(),
            hash: String.t(),
            node: node(),
            deployed_at: DateTime.t()
          }
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Starts the registry. `name:` defaults to `#{__MODULE__}`."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Registers or updates a service name with its hash and deploy node."
  def register(server \\ __MODULE__, name, hash, deploy_node) do
    GenServer.call(server, {:register, name, hash, deploy_node})
  end

  @doc "Looks up a service locally. Returns `{:ok, %Entry{}}` or `:not_found`."
  def lookup(server \\ __MODULE__, name) do
    GenServer.call(server, {:lookup, name})
  end

  @doc """
  Resolves a service by name. Checks locally first, then asks peer nodes.
  Returns `{:ok, %Entry{}}` or `:not_found`.
  """
  def resolve(server \\ __MODULE__, name) do
    GenServer.call(server, {:resolve, name}, :infinity)
  end

  @doc "Returns all registered entries."
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc "Unregisters a service by name."
  def unregister(server \\ __MODULE__, name) do
    GenServer.call(server, {:unregister, name})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(name) do
    table = :ets.new(name, [:set, :protected, {:read_concurrency, true}])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, name, hash, deploy_node}, _from, state) do
    entry = %Entry{
      name: name,
      hash: hash,
      node: deploy_node,
      deployed_at: DateTime.utc_now()
    }

    :ets.insert(state.table, {name, entry})
    {:reply, {:ok, entry}, state}
  end

  def handle_call({:lookup, name}, _from, state) do
    result =
      case :ets.lookup(state.table, name) do
        [{^name, entry}] -> {:ok, entry}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  def handle_call({:resolve, name}, _from, state) do
    result =
      case :ets.lookup(state.table, name) do
        [{^name, entry}] ->
          {:ok, entry}

        [] ->
          ask_peers(Node.list(), name)
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, state) do
    entries =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_name, entry} -> entry end)

    {:reply, entries, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(state.table, name)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ask_peers([], _name), do: :not_found

  defp ask_peers([peer | rest], name) do
    try do
      case GenServer.call({__MODULE__, peer}, {:lookup, name}, 5_000) do
        {:ok, entry} -> {:ok, entry}
        :not_found -> ask_peers(rest, name)
      end
    catch
      :exit, _ -> ask_peers(rest, name)
    end
  end
end
