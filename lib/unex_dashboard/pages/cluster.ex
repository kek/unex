defmodule Unex.Dashboard.Pages.Cluster do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  alias Unex.Dashboard.Events

  @impl true
  def menu_link(_session, _caps), do: {:ok, "Cluster"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unex.PubSub, Events.topic_cluster())
    end

    {:ok, assign(socket, nodes: gather_nodes())}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply, assign(socket, nodes: gather_nodes())}
  end

  @impl true
  def handle_info({:cluster, _event}, socket) do
    {:noreply, assign(socket, nodes: gather_nodes())}
  end

  defp gather_nodes do
    [node() | Node.list()] |> Enum.map(&Atom.to_string/1)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card title={"Cluster (#{length(@nodes)} node(s))"}>
      <p>{Enum.join(@nodes, ", ")}</p>
      {Phoenix.HTML.raw(svg(@nodes))}
    </.card>
    """
  end

  # Server-rendered SVG. Places nodes on a circle; draws a star from the
  # first node (this one) to every peer. No JS, no hooks.
  defp svg([]), do: ~s(<p><em>No nodes connected.</em></p>)

  defp svg(nodes) do
    w = 640
    h = 360
    cx = div(w, 2)
    cy = div(h, 2)
    r = 130

    count = length(nodes)

    coords =
      nodes
      |> Enum.with_index()
      |> Enum.map(fn {name, i} ->
        if count == 1 do
          {name, cx, cy}
        else
          theta = 2 * :math.pi() * i / count - :math.pi() / 2
          {name, cx + round(r * :math.cos(theta)), cy + round(r * :math.sin(theta))}
        end
      end)

    [{_, ox, oy} | rest] = coords

    lines =
      for {_name, x, y} <- rest do
        ~s(<line x1="#{ox}" y1="#{oy}" x2="#{x}" y2="#{y}" stroke="#888" stroke-width="1.5"/>)
      end

    circles =
      for {name, x, y} <- coords do
        [
          ~s(<circle cx="#{x}" cy="#{y}" r="28" fill="#4f46e5"/>),
          ~s(<text x="#{x}" y="#{y + 4}" text-anchor="middle" font-size="11" fill="white">#{escape(name)}</text>)
        ]
      end

    """
    <svg viewBox="0 0 #{w} #{h}" width="100%" style="max-height: 380px; background: #fafafa; border: 1px solid #eee; border-radius: 4px;">
      #{Enum.join(lines, "\n")}
      #{Enum.join(List.flatten(circles), "\n")}
    </svg>
    """
  end

  defp escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
