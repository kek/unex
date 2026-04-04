defmodule Uniops.MixProject do
  use Mix.Project

  def project do
    [
      app: :uniops,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia],
      mod: {Uniops.Application, []}
    ]
  end

  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"}
    ]
  end
end
