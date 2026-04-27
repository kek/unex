defmodule Unex.Dashboard.Pages.Services do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder

  alias Unex.Dashboard.Events
  alias Unex.Services.Registry

  @max_log 50

  @impl true
  def menu_link(_session, _caps), do: {:ok, "Services"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_services())
    end

    {:ok, assign(socket, services: services(), log: [])}
  end

  @impl true
  def handle_info({:services, event}, socket) do
    log = Enum.take([format(event) | socket.assigns.log], @max_log)
    {:noreply, assign(socket, services: services(), log: log)}
  end

  defp services do
    Registry.list()
  catch
    :exit, _ -> []
  end

  defp endpoint_url(name) do
    "#{api_base_url()}/#{URI.encode(name)}"
  end

  defp api_base_url do
    case Application.get_env(:unex, :api_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        port = Application.get_env(:unex, :api_port, 4040)
        "http://localhost:#{port}"
    end
  end

  defp format(event), do: "#{now_stamp()} #{format_event(event)}"

  defp now_stamp do
    DateTime.utc_now()
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_event({:registered, name, hash, node}),
    do: "[registered] #{name} → #{String.slice(hash, 0, 10)}… on #{inspect(node)}"

  defp format_event({:unregistered, name}), do: "[unregistered] #{name}"
  defp format_event({:call_started, name, node}), do: "[call start] #{name} on #{inspect(node)}"
  defp format_event({:call_finished, name, node}), do: "[call end]   #{name} on #{inspect(node)}"
  defp format_event(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <.card title="Deployed services">
      <table :if={@services != []} class="table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Hash</th>
            <th>Node</th>
            <th>Deployed</th>
            <th>Endpoint</th>
            <th>Source</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @services}>
            <td><strong>{s.name}</strong></td>
            <td>
              <.link navigate={live_dashboard_path(@socket, :hash, @page.node, %{}, %{"id" => s.hash})}>
                <code>{String.slice(s.hash, 0, 12)}…</code>
              </.link>
            </td>
            <td>{inspect(s.node)}</td>
            <td>{Calendar.strftime(s.deployed_at, "%H:%M:%S")}</td>
            <td>
              <a href={endpoint_url(s.name)} target="_blank" rel="noopener">
                /{s.name} ↗
              </a>
            </td>
            <td>
              <%= case Unex.Dashboard.SourceLink.build(s.project, s.entry_point) do %>
                <% nil -> %>
                  <span style="color:#999">—</span>
                <% link -> %>
                  <a href={link.url} target="_blank" rel="noopener">{link.host} ↗</a>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@services == []}>No services deployed.</p>
    </.card>

    <.card title="Activity">
      <pre style="max-height: 16rem; overflow:auto; background:#111; color:#9f9; padding:0.5rem; font-size:12px;"><%= Enum.join(@log, "\n") %></pre>
    </.card>
    """
  end
end
