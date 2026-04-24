defmodule Unex.Dashboard.HashLive do
  use Phoenix.LiveView, layout: {Unex.Dashboard.Layouts, :app}

  use Phoenix.VerifiedRoutes,
    endpoint: Unex.Dashboard.Endpoint,
    router: Unex.Dashboard.Router,
    statics: Unex.Dashboard.static_paths()

  alias Unex.Cluster.HashCache

  def mount(%{"id" => id}, _session, socket) do
    result =
      case safe_get(id) do
        {:ok, data} -> {:found, byte_size(data), preview(data)}
        :not_found -> :missing
      end

    {:ok, assign(socket, hash: id, result: result)}
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

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold mb-4">Hash</h1>
    <p class="font-mono text-sm break-all">{@hash}</p>

    <div :if={@result == :missing} class="mt-4 text-red-600">Blob not found in local cache.</div>

    <div :if={match?({:found, _, _}, @result)} class="mt-4">
      <p class="text-sm">{elem(@result, 1)} bytes</p>
      <pre class="mt-2 bg-zinc-900 text-zinc-100 p-3 text-xs rounded whitespace-pre-wrap break-all"><%= elem(@result, 2) %></pre>
    </div>
    """
  end
end
