defmodule Uniops.Application do
  use Application

  @impl true
  def start(_type, _args) do
    mnesia_dir = Application.get_env(:uniops, :mnesia_dir)
    if mnesia_dir, do: Uniops.Storage.Schema.init(mnesia_dir)

    children =
      if Application.get_env(:uniops, :start_api, false) do
        port = Application.get_env(:uniops, :api_port, 4040)
        [{Bandit, plug: Uniops.API.Router, port: port}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Uniops.Supervisor)
  end
end
