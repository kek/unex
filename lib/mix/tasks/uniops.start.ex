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
    # Ensure runtime config is applied
    ensure_config()
    Application.put_env(:uniops, :start_api, true)
    Mix.Task.run("app.start")

    port = Application.get_env(:uniops, :api_port, 4040)
    IO.puts("[uniops] API listening on http://localhost:#{port}")
    IO.puts("[uniops] Press Ctrl+C to stop")

    Process.sleep(:infinity)
  end

  defp ensure_config do
    # Read all UNIOPS_* env vars and apply them, filling in defaults for anything unset.
    # This mirrors config/runtime.exs logic for the dev Mix task path.
    data_dir = System.get_env("UNIOPS_DATA") || "./data"
    mnesia_dir = Path.join(data_dir, "mnesia")
    blobs_dir = Path.join(data_dir, "blobs")
    File.mkdir_p!(mnesia_dir)
    File.mkdir_p!(blobs_dir)

    port =
      case System.get_env("UNIOPS_PORT") do
        nil -> 4040
        val -> String.to_integer(val)
      end

    encryption_key =
      case System.get_env("UNIOPS_CONFIG_KEY") do
        nil ->
          key = :crypto.strong_rand_bytes(32) |> Base.encode64()
          IO.puts("[uniops] No encryption key configured. Generated: #{key}")
          IO.puts("[uniops] Set UNIOPS_CONFIG_KEY to persist this key across restarts.")
          IO.puts("[uniops] WARNING: If the key changes, existing encrypted Config values become unreadable.")
          key

        key ->
          key
      end

    peers =
      case System.get_env("UNIOPS_PEERS") do
        nil -> []
        val -> String.split(val, ",", trim: true) |> Enum.map(&String.trim/1)
      end

    Application.put_env(:uniops, :api_port, port)
    Application.put_env(:uniops, :mnesia_dir, mnesia_dir)
    Application.put_env(:uniops, :blobs_dir, blobs_dir)
    Application.put_env(:uniops, :config_encryption_key, encryption_key)
    Application.put_env(:uniops, :ucm_path, System.get_env("UCM_PATH") || "ucm")
    Application.put_env(:uniops, :peers, peers)
  end
end
