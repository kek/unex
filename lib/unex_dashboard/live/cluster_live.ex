defmodule Unex.Dashboard.ClusterLive do
  use Phoenix.LiveView, layout: {Unex.Dashboard.Layouts, :app}

  use Phoenix.VerifiedRoutes,
    endpoint: Unex.Dashboard.Endpoint,
    router: Unex.Dashboard.Router,
    statics: Unex.Dashboard.static_paths()

  alias Unex.Dashboard.Events

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_cluster())
      Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_hashcache())
    end

    nodes = gather_nodes()

    socket =
      socket
      |> assign(nodes: nodes)
      |> maybe_push_initial_graph()

    {:ok, socket}
  end

  def handle_info({:cluster, event}, socket) do
    nodes = gather_nodes()

    socket =
      socket
      |> assign(nodes: nodes)
      |> push_event("graph:update", graph_payload(nodes))
      |> flash_for(event)

    {:noreply, socket}
  end

  def handle_info({:hashcache, _event}, socket), do: {:noreply, socket}

  defp gather_nodes do
    [node() | Node.list()] |> Enum.map(&Atom.to_string/1)
  end

  defp graph_payload([]), do: %{nodes: [], links: []}

  defp graph_payload([first | rest] = node_names) do
    nodes = Enum.map(node_names, fn n -> %{id: n} end)
    links = Enum.map(rest, fn n -> %{source: first, target: n} end)
    %{nodes: nodes, links: links}
  end

  defp maybe_push_initial_graph(socket) do
    if connected?(socket) do
      push_event(socket, "graph:update", graph_payload(socket.assigns.nodes))
    else
      socket
    end
  end

  defp flash_for(socket, {:hash_replicated, from, to, _hash}) do
    push_event(socket, "graph:flash", %{
      from: Atom.to_string(from),
      to: Atom.to_string(to)
    })
  end

  defp flash_for(socket, _other), do: socket

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold mb-4">Cluster</h1>
    <p class="text-zinc-600 mb-4">
      {length(@nodes)} node(s): {Enum.join(@nodes, ", ")}
    </p>
    <div id="cluster-graph"
         phx-hook="ClusterGraph"
         phx-update="ignore"
         class="w-full h-[420px] border border-zinc-200 rounded bg-white">
    </div>
    """
  end
end
