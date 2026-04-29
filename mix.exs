defmodule Unex.MixProject do
  use Mix.Project

  def project do
    [
      app: :unex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia, :os_mon],
      mod: {Unex.Application, []}
    ]
  end

  defp elixirc_paths(_env), do: ["lib"]

  defp releases do
    [
      unex: [
        include_executables_for: [:unix],
        rel_templates_path: "rel"
      ]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:exsync, "~> 0.4", only: :dev}
    ]
  end
end
