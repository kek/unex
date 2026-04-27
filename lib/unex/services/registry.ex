defmodule Unex.Services.Registry do
  @moduledoc """
  ETS-backed registry mapping service names to their bytecode hashes
  and deployment metadata. Supports cross-node resolution.

  When started with `persist?: true`, registry mutations are written
  through to a Mnesia disc-copy table so service deployments survive
  process and node restarts. The ETS table is the read path; Mnesia is
  the durable backing store and is hydrated into ETS on init.
  """

  use GenServer

  alias Unex.Storage.Schema

  defmodule Entry do
    @moduledoc "A registered service entry."
    defstruct [:name, :hash, :node, :deployed_at, :project, :entry_point]

    @type t :: %__MODULE__{
            name: String.t(),
            hash: String.t(),
            node: node(),
            deployed_at: DateTime.t(),
            project: String.t() | nil,
            entry_point: String.t() | nil
          }
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the registry. Options:
    * `:name` — registered process name (default `#{__MODULE__}`)
    * `:persist?` — when true, mirror writes to the `:unex_services` Mnesia
      table and hydrate ETS from it on init (default `false`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers or updates a service name with its hash and deploy node.
  `opts` may include `:project` and `:entry_point` (both strings) — captured
  from the original deploy so the dashboard can link back to source.
  """
  def register(server \\ __MODULE__, name, hash, deploy_node, opts \\ []) do
    GenServer.call(server, {:register, name, hash, deploy_node, opts})
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
  def init(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    persist? = Keyword.get(opts, :persist?, false)
    table = :ets.new(name, [:set, :protected, {:read_concurrency, true}])
    if persist?, do: hydrate_from_mnesia(table)
    {:ok, %{table: table, persist?: persist?}}
  end

  # Backwards-compatible: old callers passed just the name as init arg.
  def init(name) when is_atom(name) do
    init(name: name)
  end

  @impl true
  def handle_call({:register, name, hash, deploy_node, opts}, _from, state) do
    entry = %Entry{
      name: name,
      hash: hash,
      node: deploy_node,
      deployed_at: DateTime.utc_now(),
      project: Keyword.get(opts, :project),
      entry_point: Keyword.get(opts, :entry_point)
    }

    :ets.insert(state.table, {name, entry})
    if state.persist?, do: persist_write(name, entry)
    Unex.Dashboard.Events.broadcast_services({:registered, name, hash, deploy_node})
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
    if state.persist?, do: persist_delete(name)
    Unex.Dashboard.Events.broadcast_services({:unregistered, name})
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

  defp hydrate_from_mnesia(table) do
    table_name = Schema.services_table()

    case :mnesia.transaction(fn ->
           :mnesia.foldl(
             fn {^table_name, name, entry}, acc -> [{name, entry} | acc] end,
             [],
             table_name
           )
         end) do
      {:atomic, rows} ->
        Enum.each(rows, fn {name, entry} -> :ets.insert(table, {name, entry}) end)

      {:aborted, _reason} ->
        :ok
    end
  end

  defp persist_write(name, entry) do
    table = Schema.services_table()
    :mnesia.transaction(fn -> :mnesia.write({table, name, entry}) end)
    :ok
  end

  defp persist_delete(name) do
    table = Schema.services_table()
    :mnesia.transaction(fn -> :mnesia.delete({table, name}) end)
    :ok
  end
end
