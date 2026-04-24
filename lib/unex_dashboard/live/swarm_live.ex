defmodule Unex.Dashboard.SwarmLive do
  use Phoenix.LiveView, layout: {Unex.Dashboard.Layouts, :app}

  use Phoenix.VerifiedRoutes,
    endpoint: Unex.Dashboard.Endpoint,
    router: Unex.Dashboard.Router,
    statics: Unex.Dashboard.static_paths()

  alias Unex.Dashboard.Events

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_services())
    end

    {:ok, assign(socket, in_flight: %{}, history: [])}
  end

  def handle_info({:services, {:call_started, name, node}}, socket) do
    in_flight = Map.update(socket.assigns.in_flight, {node, name}, 1, &(&1 + 1))
    {:noreply, assign(socket, in_flight: in_flight)}
  end

  def handle_info({:services, {:call_finished, name, node}}, socket) do
    key = {node, name}

    in_flight =
      Map.update(socket.assigns.in_flight, key, 0, fn n -> max(n - 1, 0) end)

    history = Enum.take([{DateTime.utc_now(), key} | socket.assigns.history], 50)
    {:noreply, assign(socket, in_flight: in_flight, history: history)}
  end

  def handle_info({:services, _}, socket), do: {:noreply, socket}

  defp total(in_flight), do: in_flight |> Map.values() |> Enum.sum()

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold mb-4">Swarm</h1>
    <p class="text-zinc-600 mb-4">{total(@in_flight)} in-flight call(s).</p>

    <table :if={map_size(@in_flight) > 0} class="min-w-full text-sm">
      <thead class="bg-zinc-100 text-left">
        <tr>
          <th class="px-3 py-2">Node</th>
          <th class="px-3 py-2">Service</th>
          <th class="px-3 py-2">In flight</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{{node, name}, count} <- @in_flight} class="border-t border-zinc-100">
          <td class="px-3 py-2">{inspect(node)}</td>
          <td class="px-3 py-2">{name}</td>
          <td class="px-3 py-2">{count}</td>
        </tr>
      </tbody>
    </table>
    """
  end
end
