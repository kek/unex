defmodule Mix.Tasks.Uniops.Start do
  @moduledoc """
  Starts a Uniops node.

  ## Usage

      mix uniops.start                              # single node, zero config
      mix uniops.start --config path/to/config.exs   # with config file

  ## Environment Variables

  All UNIOPS_* env vars are supported. See the README for details.

  When UNIOPS_NODE is set, the task re-launches with BEAM distribution flags
  and drops into an IEx shell.
  """

  use Mix.Task

  @shortdoc "Start a Uniops node"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [config: :string])

    if config_path = opts[:config] do
      System.put_env("UNIOPS_CONFIG", config_path)
    end

    node_name = System.get_env("UNIOPS_NODE")
    cookie = System.get_env("UNIOPS_COOKIE")

    if node_name do
      reexec_with_distribution(node_name, cookie)
    else
      start_without_distribution()
    end
  end

  defp reexec_with_distribution(node_name, cookie) do
    unless cookie do
      Mix.raise("UNIOPS_COOKIE is required when UNIOPS_NODE is set")
    end

    node_flag =
      if String.contains?(node_name, "@"),
        do: "--name",
        else: "--sname"

    args = [
      node_flag, node_name,
      "--cookie", cookie,
      "-S", "mix", "run", "--no-halt"
    ]

    iex_path = System.find_executable("iex") || "iex"

    Port.open({:spawn_executable, iex_path}, [
      :binary,
      :nouse_stdio,
      args: args
    ])

    receive do
      _ -> :ok
    end
  end

  defp start_without_distribution do
    Application.put_env(:uniops, :start_api, true)
    Mix.Task.run("app.start")

    port = Application.get_env(:uniops, :api_port, 4040)
    IO.puts("[uniops] API listening on http://localhost:#{port}")
    IO.puts("[uniops] Press Ctrl+C to stop")

    Process.sleep(:infinity)
  end
end
