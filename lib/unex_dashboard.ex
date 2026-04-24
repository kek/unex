defmodule Unex.Dashboard do
  @moduledoc "Namespace for the dashboard subsystem."

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Unex.Dashboard.Endpoint,
        router: Unex.Dashboard.Router,
        statics: Unex.Dashboard.static_paths()
    end
  end
end
