defmodule Unex.Dashboard.Pages.Hash do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder

  alias Unex.Cluster.HashCache

  @impl true
  def menu_link(_session, _caps), do: {:ok, "Hash"}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    id = assigns.page.params["id"]
    assigns = Map.put(assigns, :result, lookup(id))
    assigns = Map.put(assigns, :hash, id)

    ~H"""
    <.card :if={is_nil(@hash)} title="Hash inspector">
      <p>Append <code>?id=&lt;hash&gt;</code> to the URL or click a hash on the Services page.</p>
    </.card>

    <.fields_card
      :if={match?({:found, _, _}, @result)}
      title="Blob"
      fields={[
        {"Hash", @hash},
        {"Size (bytes)", elem(@result, 1) |> Integer.to_string()},
        {"Preview (first 256 bytes)", elem(@result, 2)}
      ]}
    />

    <.card :if={@result == :missing} title="Blob">
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
end
