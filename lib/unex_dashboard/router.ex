defmodule Unex.Dashboard.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Unex.Dashboard.BasicAuth)
  end

  scope "/" do
    pipe_through(:browser)

    get("/", Unex.Dashboard.Redirect, :to_dashboard)

    live_dashboard("/dashboard",
      metrics: Unex.Dashboard.Telemetry,
      additional_pages: [
        services: Unex.Dashboard.Pages.Services,
        cluster: Unex.Dashboard.Pages.Cluster,
        swarm: Unex.Dashboard.Pages.Swarm,
        hash: Unex.Dashboard.Pages.Hash
      ]
    )
  end
end
