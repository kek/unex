defmodule Unex.Dashboard.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Unex.Dashboard.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Unex.Dashboard.BasicAuth)
  end

  scope "/", Unex.Dashboard do
    pipe_through(:browser)

    live_session :dashboard, root_layout: {Unex.Dashboard.Layouts, :root} do
      live("/", IndexLive, :index)
      live("/services", ServicesLive, :index)
    end

    live_dashboard("/dashboard", metrics: Unex.Dashboard.Telemetry)
  end
end
