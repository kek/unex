defmodule Mix.Tasks.Unex.Start do
  @moduledoc """
  Starts a Unex node.

  ## Usage

      mix unex.start                              # single node, zero config
      mix unex.start --config path/to/config.exs   # with config file

  ## Environment Variables

  All UNEX_* env vars are supported. See the README for details.

  When UNEX_NODE is set, the task re-launches with BEAM distribution flags
  and drops into an IEx shell.
  """

  use Mix.Task

  @shortdoc "Start a Unex node"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [config: :string])

    if config_path = opts[:config] do
      System.put_env("UNEX_CONFIG", config_path)
    end

    node_name = System.get_env("UNEX_NODE")
    cookie = System.get_env("UNEX_COOKIE")

    if node_name do
      reexec_with_distribution(node_name, cookie)
    else
      start_without_distribution()
    end
  end

  defp reexec_with_distribution(node_name, cookie) do
    unless cookie do
      Mix.raise("UNEX_COOKIE is required when UNEX_NODE is set")
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
    Application.put_env(:unex, :start_api, true)
    Mix.Task.run("app.start")

    port = Application.get_env(:unex, :api_port, 4040)
    IO.puts("[unex] API listening on http://localhost:#{port}")
    IO.puts("[unex] Press Ctrl+C to stop")

    Process.sleep(:infinity)
  end

  defp ensure_config do
    # Read all UNEX_* env vars and apply them, filling in defaults for anything unset.
    # This mirrors config/runtime.exs logic for the dev Mix task path.
    data_dir = System.get_env("UNEX_DATA") || "./data"
    mnesia_dir = Path.join(data_dir, "mnesia")
    blobs_dir = Path.join(data_dir, "blobs")
    File.mkdir_p!(mnesia_dir)
    File.mkdir_p!(blobs_dir)

    port =
      case System.get_env("UNEX_PORT") do
        nil -> 4040
        val -> String.to_integer(val)
      end

    encryption_key =
      case System.get_env("UNEX_CONFIG_KEY") do
        nil ->
          key = :crypto.strong_rand_bytes(32) |> Base.encode64()
          IO.puts("[unex] No encryption key configured. Generated: #{key}")
          IO.puts("[unex] Set UNEX_CONFIG_KEY to persist this key across restarts.")
          IO.puts("[unex] WARNING: If the key changes, existing encrypted Config values become unreadable.")
          key

        key ->
          key
      end

    api_secret =
      case System.get_env("UNEX_API_SECRET") do
        nil ->
          secret = Base.encode64(:crypto.strong_rand_bytes(32))
          IO.puts("[unex] No API secret configured. Generated: #{secret}")
          IO.puts("[unex] Set UNEX_API_SECRET to persist this secret across restarts.")
          secret

        secret ->
          secret
      end

    peers =
      case System.get_env("UNEX_PEERS") do
        nil -> []
        val -> String.split(val, ",", trim: true) |> Enum.map(&String.trim/1)
      end

    Application.put_env(:unex, :api_port, port)
    Application.put_env(:unex, :mnesia_dir, mnesia_dir)
    Application.put_env(:unex, :blobs_dir, blobs_dir)
    Application.put_env(:unex, :config_encryption_key, encryption_key)
    Application.put_env(:unex, :api_secret, api_secret)
    Application.put_env(:unex, :ucm_path, System.get_env("UCM_PATH") || "ucm")
    Application.put_env(:unex, :peers, peers)
  end
end
