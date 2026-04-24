defmodule Unex.Dashboard.ServicesLive do
  use Phoenix.LiveView, layout: {Unex.Dashboard.Layouts, :app}

  use Phoenix.VerifiedRoutes,
    endpoint: Unex.Dashboard.Endpoint,
    router: Unex.Dashboard.Router,
    statics: Unex.Dashboard.static_paths()

  alias Unex.Dashboard.Events
  alias Unex.Services.Registry

  @max_log 50

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_services())
    end

    services =
      try do
        Registry.list()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    {:ok, assign(socket, services: services, log: [])}
  end

  def handle_info({:services, event}, socket) do
    services =
      try do
        Registry.list()
      rescue
        _ -> socket.assigns.services
      catch
        :exit, _ -> socket.assigns.services
      end

    log = Enum.take([format(event) | socket.assigns.log], @max_log)
    {:noreply, assign(socket, services: services, log: log)}
  end

  defp format({:registered, name, hash, node}),
    do: "[registered] #{name} → #{String.slice(hash, 0, 10)}… on #{inspect(node)}"

  defp format({:unregistered, name}),
    do: "[unregistered] #{name}"

  defp format(other), do: inspect(other)

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold mb-4">Services</h1>

    <div :if={@services == []} class="text-zinc-500">No services deployed.</div>

    <table :if={@services != []} class="min-w-full text-sm">
      <thead class="bg-zinc-100 text-left">
        <tr>
          <th class="px-3 py-2">Name</th>
          <th class="px-3 py-2">Hash</th>
          <th class="px-3 py-2">Node</th>
          <th class="px-3 py-2">Deployed</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={s <- @services} class="border-t border-zinc-100">
          <td class="px-3 py-2 font-medium">{s.name}</td>
          <td class="px-3 py-2 font-mono text-xs">
            <.link navigate={~p"/hash/#{s.hash}"}>{String.slice(s.hash, 0, 12)}…</.link>
          </td>
          <td class="px-3 py-2">{inspect(s.node)}</td>
          <td class="px-3 py-2">{Calendar.strftime(s.deployed_at, "%H:%M:%S")}</td>
        </tr>
      </tbody>
    </table>

    <h2 class="text-lg font-semibold mt-6 mb-2">Activity</h2>
    <pre class="bg-black text-green-300 p-3 text-xs rounded h-64 overflow-auto"><%= Enum.join(@log, "\n") %></pre>
    """
  end
end
