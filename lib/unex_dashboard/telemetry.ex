defmodule Unex.Dashboard.Telemetry do
  @moduledoc false
  use Supervisor

  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller,
       measurements: periodic_measurements(), period: 10_000, name: Unex.Dashboard.PollerBasic}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # VM
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Unex
      last_value("unex.hashcache.count"),
      last_value("unex.hashcache.total_bytes", unit: :byte),
      last_value("unex.services.count")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :dispatch_hashcache_stats, []},
      {__MODULE__, :dispatch_services_count, []}
    ]
  end

  def dispatch_hashcache_stats do
    stats = Unex.Cluster.HashCache.stats()
    :telemetry.execute([:unex, :hashcache], stats, %{})
  end

  def dispatch_services_count do
    count = length(Unex.Services.Registry.list())
    :telemetry.execute([:unex, :services], %{count: count}, %{})
  end
end
