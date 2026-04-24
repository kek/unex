defmodule Unex.Dashboard.Pages.Code do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  alias Unex.Cluster.HashCache
  alias Unex.Cluster.SourceCache
  alias Unex.Dashboard.SourceLink
  alias Unex.Services.Registry

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
      row_attrs={&row_attrs/1}
      default_sort_by={:added}
      title={title()}
    >
      <:col field={:hash} header="Hash" />
      <:col :let={row} field={:size} header="Size" text_align="right" sortable={:desc}>
        {format_bytes(row.size)}
      </:col>
      <:col :let={row} field={:added} header="Added" sortable={:desc}>
        {format_ts(row.added)}
      </:col>
      <:col :let={row} field={:source} header="Source">
        {source_badge(row)}
      </:col>
    </.live_table>
    """
  end

  # ---- row fetching ---------------------------------------------------------

  defp fetch_rows(params, _node) do
    %{search: search, sort_by: sort_by, sort_dir: sort_dir, limit: limit} = params

    service_index = build_service_index()

    rows =
      HashCache.list_with_meta()
      |> Enum.map(fn {hash, size, ts} ->
        {share_link, has_source} = enrichment_for(hash, service_index)

        %{
          hash: hash,
          size: size,
          added: ts,
          share_link: share_link,
          has_source: has_source
        }
      end)
      |> maybe_filter(search)

    total = length(rows)
    {slice(rows, sort_by, sort_dir, limit), total}
  end

  defp maybe_filter(rows, s) when s in [nil, ""], do: rows

  defp maybe_filter(rows, needle) do
    Enum.filter(rows, fn %{hash: h} -> String.contains?(h, needle) end)
  end

  defp slice(rows, sort_by, sort_dir, limit) do
    rows
    |> Enum.sort_by(&Map.get(&1, sort_by || :added), sort_dir || :desc)
    |> Enum.take(limit || 50)
  end

  defp row_attrs(row) do
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

  # ---- enrichment -----------------------------------------------------------

  # Build a map of root_hash → %{project, entry_point} from the registry so we
  # can annotate every row without hitting the registry N times.
  defp build_service_index do
    Registry.list()
    |> Enum.into(%{}, fn entry -> {entry.hash, entry} end)
  catch
    :exit, _ -> %{}
  end

  defp enrichment_for(hash, service_index) do
    has_source =
      case safe_source_get(hash) do
        {:ok, _} -> true
        :not_found -> false
      end

    share_link =
      case Map.get(service_index, hash) do
        nil -> nil
        entry -> SourceLink.build(entry.project, entry.entry_point)
      end

    {share_link, has_source}
  end

  defp safe_source_get(hash) do
    SourceCache.get(hash)
  catch
    :exit, _ -> :not_found
  end

  # ---- presentation ---------------------------------------------------------

  defp source_badge(%{has_source: true, share_link: %{url: url, host: host}}) do
    Phoenix.HTML.raw(~s(✓ cached · <a href="#{url}" target="_blank" rel="noopener">#{host} ↗</a>))
  end

  defp source_badge(%{has_source: true}), do: "✓ cached"

  defp source_badge(%{share_link: %{url: url, host: host}}) do
    Phoenix.HTML.raw(~s(<a href="#{url}" target="_blank" rel="noopener">#{host} ↗</a>))
  end

  defp source_badge(_), do: Phoenix.HTML.raw(~s(<span style="color:#999">—</span>))

  defp title do
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

  defp format_ts(0), do: "—"

  defp format_ts(ms) when is_integer(ms) do
    dt = DateTime.from_unix!(ms, :millisecond) |> DateTime.shift_zone!("Etc/UTC")
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end
end
