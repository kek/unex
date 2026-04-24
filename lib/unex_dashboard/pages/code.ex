defmodule Unex.Dashboard.Pages.Code do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  alias Unex.Cluster.HashCache

  @impl true
  def menu_link(_session, _caps), do: {:ok, "Code"}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_table
      id="code-table"
      dom_id="code-table"
      page={@page}
      row_fetcher={&fetch_rows/2}
      row_attrs={&row_attrs(&1, @page)}
      title={title(@page)}
    >
      <:col field={:hash} header="Hash" />
      <:col field={:size} header="Size (bytes)" text_align="right" sortable={:desc} />
    </.live_table>
    """
  end

  defp fetch_rows(params, _node) do
    %{search: search, sort_by: sort_by, sort_dir: sort_dir, limit: limit} = params

    rows =
      HashCache.list_with_sizes()
      |> Enum.map(fn {hash, size} -> %{hash: hash, size: size} end)
      |> maybe_filter(search)

    total = length(rows)
    {slice(rows, sort_by, sort_dir, limit), total}
  end

  defp maybe_filter(rows, nil), do: rows
  defp maybe_filter(rows, ""), do: rows

  defp maybe_filter(rows, needle) do
    Enum.filter(rows, fn %{hash: h} -> String.contains?(h, needle) end)
  end

  defp slice(rows, sort_by, sort_dir, limit) do
    rows
    |> Enum.sort_by(&Map.get(&1, sort_by || :size), sort_dir || :desc)
    |> Enum.take(limit || 50)
  end

  defp row_attrs(row, _page) do
    [
      {"phx-click", "goto"},
      {"phx-value-hash", row.hash},
      {"style", "cursor: pointer"}
    ]
  end

  @impl true
  def handle_event("goto", %{"hash" => hash}, socket) do
    path =
      Phoenix.LiveDashboard.PageBuilder.live_dashboard_path(
        socket,
        :hash,
        socket.assigns.page.node,
        %{},
        %{"id" => hash}
      )

    {:noreply, Phoenix.LiveView.push_navigate(socket, to: path)}
  end

  defp title(%{}) do
    case safe_stats() do
      %{count: count, total_bytes: bytes} ->
        "Code — #{count} blob(s), #{format_bytes(bytes)}"

      _ ->
        "Code"
    end
  end

  defp safe_stats do
    HashCache.stats()
  catch
    :exit, _ -> nil
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MiB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GiB"
end
