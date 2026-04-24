defmodule Unex.Dashboard.Pages.Swarm do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder

  alias Unex.Dashboard.Events

  @impl true
  def menu_link(_session, _caps), do: {:ok, "Swarm"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_services())
    end

    {:ok, assign(socket, in_flight: %{})}
  end

  @impl true
  def handle_info({:services, {:call_started, name, node}}, socket) do
    in_flight = Map.update(socket.assigns.in_flight, {node, name}, 1, &(&1 + 1))
    {:noreply, assign(socket, in_flight: in_flight)}
  end

  @impl true
  def handle_info({:services, {:call_finished, name, node}}, socket) do
    in_flight =
      Map.update(socket.assigns.in_flight, {node, name}, 0, fn n -> max(n - 1, 0) end)

    {:noreply, assign(socket, in_flight: in_flight)}
  end

  def handle_info({:services, _}, socket), do: {:noreply, socket}

  defp total(in_flight), do: in_flight |> Map.values() |> Enum.sum()

  @impl true
  def render(assigns) do
    ~H"""
    <.card title={"Swarm — #{total(@in_flight)} in-flight"}>
      <table :if={map_size(@in_flight) > 0} class="table">
        <thead>
          <tr><th>Node</th><th>Service</th><th>In flight</th></tr>
        </thead>
        <tbody>
          <tr :for={{{node, name}, count} <- @in_flight}>
            <td>{inspect(node)}</td>
            <td>{name}</td>
            <td>{count}</td>
          </tr>
        </tbody>
      </table>
      <p :if={map_size(@in_flight) == 0}>No in-flight calls.</p>
    </.card>
    """
  end
end
