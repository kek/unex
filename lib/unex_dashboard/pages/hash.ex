defmodule Unex.Dashboard.Pages.Hash do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder

  alias Unex.Cluster.HashCache
  alias Unex.Cluster.SourceCache
  alias Unex.Services.Registry

  @impl true
  def menu_link(_session, _caps), do: {:ok, "Hash"}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    id = assigns.page.params["id"]

    assigns =
      assigns
      |> Map.put(:result, lookup(id))
      |> Map.put(:hash, id)
      |> Map.put(:inserted_at, inserted_at_for(id))
      |> Map.put(:source_link, source_link_for(id))
      |> Map.put(:cached_source, cached_source_for(id))
      |> Map.put(:related_services, services_rooted_at(id))

    ~H"""
    <.card :if={is_nil(@hash)} title="Hash inspector">
      <p>Append <code>?id=&lt;hash&gt;</code> to the URL or click a hash on the Services page.</p>
    </.card>

    <.fields_card
      :if={match?({:found, _, _}, @result)}
      title="Blob"
      fields={blob_fields(@hash, @result, @inserted_at)}
    />

    <.card :if={@related_services != []} title="Deployed services rooted at this hash">
      <ul>
        <li :for={s <- @related_services}>
          <strong>{s.name}</strong>
          <span style="color:#999"> deployed {Calendar.strftime(s.deployed_at, "%Y-%m-%d %H:%M:%S UTC")} on {inspect(s.node)}</span>
        </li>
      </ul>
    </.card>

    <.card :if={@source_link} title="Source">
      <p>
        This hash is the root of a deployed service.
        <a href={@source_link.url} target="_blank" rel="noopener">
          View on {@source_link.host} ↗
        </a>
      </p>
    </.card>

    <.card :if={@cached_source} title="Source (cached from UCM)">
      <pre style="white-space: pre-wrap; word-break: break-word;"><%= @cached_source %></pre>
    </.card>

    <.card :if={@result == :missing and not is_nil(@hash)} title="Blob">
      <p>Blob <code>{@hash}</code> not found in the local cache.</p>
    </.card>
    """
  end

  defp lookup(nil), do: :missing

  defp lookup(id) do
    case safe_get(id) do
      {:ok, data} -> {:found, byte_size(data), preview(data)}
      :not_found -> :missing
    end
  end

  defp safe_get(id) do
    HashCache.get(id)
  catch
    :exit, _ -> :not_found
  end

  defp preview(data) do
    head = binary_part(data, 0, min(byte_size(data), 256))
    if String.valid?(head), do: head, else: Base.encode16(head, case: :lower)
  end

  defp source_link_for(nil), do: nil

  defp source_link_for(id) do
    case find_service_by_hash(id) do
      nil -> nil
      %{project: project, entry_point: entry} -> Unex.Dashboard.SourceLink.build(project, entry)
    end
  end

  defp cached_source_for(nil), do: nil

  defp cached_source_for(id) do
    case safe_source_get(id) do
      {:ok, source} -> source
      :not_found -> nil
    end
  end

  defp safe_source_get(id) do
    SourceCache.get(id)
  catch
    :exit, _ -> :not_found
  end

  defp find_service_by_hash(hash) do
    Enum.find(services(), &(&1.hash == hash))
  end

  defp services_rooted_at(nil), do: []
  defp services_rooted_at(hash), do: Enum.filter(services(), &(&1.hash == hash))

  defp inserted_at_for(nil), do: nil

  defp inserted_at_for(hash) do
    HashCache.inserted_at(hash)
  catch
    :exit, _ -> nil
  end

  defp blob_fields(hash, {:found, size, preview_text}, inserted_at) do
    base = [
      {"Hash", hash},
      {"Size (bytes)", Integer.to_string(size)}
    ]

    added =
      case inserted_at do
        nil -> []
        0 -> []
        ms -> [{"Added", format_ts(ms)}]
      end

    base ++ added ++ [{"Preview (first 256 bytes)", preview_text}]
  end

  defp format_ts(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp services do
    Registry.list()
  catch
    :exit, _ -> []
  end
end
