defmodule Unex.MixProject do
  use Mix.Project

  def project do
    [
      app: :unex,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia],
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
      {:jason, "~> 1.4"}
    ]
  end
end
