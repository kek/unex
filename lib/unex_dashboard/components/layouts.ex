defmodule Unex.Dashboard.Layouts do
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: Unex.Dashboard.Endpoint,
    router: Unex.Dashboard.Router,
    statics: Unex.Dashboard.static_paths()

  embed_templates("layouts/*")
end
