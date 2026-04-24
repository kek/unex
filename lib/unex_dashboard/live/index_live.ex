defmodule Unex.Dashboard.IndexLive do
  use Phoenix.LiveView, layout: {Unex.Dashboard.Layouts, :app}

  use Phoenix.VerifiedRoutes,
    endpoint: Unex.Dashboard.Endpoint,
    router: Unex.Dashboard.Router,
    statics: Unex.Dashboard.static_paths()

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold">Unex Dashboard</h1>
    <p class="mt-2 text-zinc-600">
      Pick a view from the nav bar, or dive into the metrics tab for VM and runtime stats.
    </p>
    """
  end
end
