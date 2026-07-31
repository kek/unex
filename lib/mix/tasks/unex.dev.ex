defmodule Mix.Tasks.Unex.Dev do
  @moduledoc """
  Runs a real Unex node on this machine, in one command.

      mix unex.dev
      mix unex.dev --dashboard
      mix unex.dev --data /tmp/unex-scratch --port 4444
      mix unex.dev --check          # preflight and print the banner, don't boot

  This is *not* a simplified re-implementation of Unex. It sets environment
  variables, lets `config/runtime.exs` resolve them exactly as a release boot
  does, and starts the ordinary `Unex.Application` supervision tree. The only
  things it adds are the three pieces of local-development care the server
  cannot do for itself:

    1. **Dispatcher bundle preflight.** A compiled `.uc` bundle records the UCM
       that built it, and UCM refuses to run a mismatched one. Left alone, a
       stale bundle costs a ten-second accept timeout per pool worker and then
       every service call fails with `:dispatcher_not_started`. This task reads
       the bundle's version first and rebuilds it via
       `mix unex.compile_dispatcher` when it does not match the local UCM.

    2. **Stable credentials.** `config/runtime.exs` generates `UNEX_SECRET` and
       `UNEX_CONFIG_KEY` when they are unset — a fresh key each boot, which
       silently makes every previously written encrypted `Unex.Config` value
       unreadable. This task persists whatever was generated into
       `<data-dir>/dev.env` and reuses it next time.

    3. **One data directory.** `Unex.Runtime` and `Unex.Dispatcher` read
       `:data_dir`, which nothing derived from `UNEX_DATA` until now — so the
       runtime codebase and the dispatcher bundle could end up beside the
       current working directory while Mnesia went somewhere else entirely.

  Options:

    * `--data PATH` — data directory. Defaults to `UNEX_DATA`, else
      `~/.local/share/unex/dev`.
    * `--port N` — API port (`UNEX_PORT`, default 4040).
    * `--dashboard` — also start the LiveView dashboard on `:4041`.
    * `--pool-size N` — dispatcher pool size. Defaults to 1 locally; production
      defaults to 4.
    * `--skip-dispatcher` — do not build or check the dispatcher bundle. Service
      calls will fail; useful when you only want the storage/config API.
    * `--check` — run every preflight and print the banner, then exit without
      starting the node.

  Run it from the repository root: building the dispatcher reads
  `unison/Unex/Dispatcher.u` relative to the current directory.

  See `docs/local-dev.md`.
  """

  use Mix.Task

  @shortdoc "Run a Unex node locally for development"

  @switches [
    data: :string,
    port: :integer,
    dashboard: :boolean,
    pool_size: :integer,
    skip_dispatcher: :boolean,
    check: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    # Compile first so Unex.Dev, Unex.UCM and the compile_dispatcher task are
    # available, but do NOT let anything read config yet: config/runtime.exs
    # must see the environment we are about to set.
    Mix.Task.run("compile")

    data_dir = resolve_data_dir(opts)
    File.mkdir_p!(data_dir)

    load_persisted_credentials(data_dir)
    apply_env(opts, data_dir)

    # From here on, configuration is production's business, not ours.
    Mix.Task.run("app.config")

    persist_credentials(data_dir)

    {ucm_path, ucm_release} = preflight_ucm!()
    dispatcher_path = resolved_dispatcher_path(data_dir)
    dispatcher_version = preflight_dispatcher!(opts, dispatcher_path, ucm_release)

    info = %{
      api_url: "http://localhost:#{Application.get_env(:unex, :api_port)}",
      secret: Application.get_env(:unex, :api_secret),
      data_dir: data_dir,
      ucm_path: ucm_path,
      ucm_version: "release/#{ucm_release}",
      dispatcher_path: dispatcher_path,
      dispatcher_version: dispatcher_version,
      pool_size: Application.get_env(:unex, :dispatcher_pool_size),
      node: node(),
      dashboard: dashboard_url()
    }

    if opts[:check] do
      Mix.shell().info(Unex.Dev.banner(info))
      Mix.shell().info("--check: preflight passed, not starting the node.")
    else
      Mix.Task.run("app.start")
      Mix.shell().info(Unex.Dev.banner(info))
      Process.sleep(:infinity)
    end
  end

  # --- configuration -------------------------------------------------------

  # Same precedence production uses: an explicit flag, then the environment,
  # then a default. The default is under XDG rather than `./data` so a dev node
  # does not scribble into the checkout.
  defp resolve_data_dir(opts) do
    raw =
      opts[:data] ||
        System.get_env("UNEX_DATA") ||
        Path.join([System.user_home!(), ".local", "share", "unex", "dev"])

    Path.expand(raw)
  end

  # Persisted values are defaults, not overrides: a variable already exported in
  # the shell still wins, which is the precedence config/runtime.exs documents.
  defp load_persisted_credentials(data_dir) do
    data_dir
    |> Unex.Dev.env_file()
    |> Unex.Dev.read_env_file()
    |> Enum.each(fn {key, value} ->
      if System.get_env(key) in [nil, ""], do: System.put_env(key, value)
    end)
  end

  defp apply_env(opts, data_dir) do
    System.put_env("UNEX_DATA", data_dir)

    if port = opts[:port], do: System.put_env("UNEX_PORT", Integer.to_string(port))
    if opts[:dashboard], do: System.put_env("UNEX_DASHBOARD", "1")

    # Keep the bundle inside the data directory unless the developer said
    # otherwise, so `--data` really does move all of a node's state at once.
    if System.get_env("UNEX_DISPATCHER") in [nil, ""] do
      System.put_env("UNEX_DISPATCHER", Path.join(data_dir, "dispatcher.uc"))
    end

    pool_size = opts[:pool_size] || existing_pool_size() || 1
    System.put_env("UNEX_DISPATCHER_POOL_SIZE", Integer.to_string(pool_size))
  end

  defp existing_pool_size do
    case System.get_env("UNEX_DISPATCHER_POOL_SIZE") do
      nil -> nil
      "" -> nil
      value -> String.to_integer(value)
    end
  end

  # Read back what config/runtime.exs actually resolved and remember it, so the
  # generated secret and encryption key survive a restart. Reading them back
  # rather than generating our own is deliberate: there is exactly one place in
  # this codebase that mints these values, and it stays that way.
  defp persist_credentials(data_dir) do
    resolved = %{
      "UNEX_SECRET" => Application.get_env(:unex, :api_secret),
      "UNEX_CONFIG_KEY" => Application.get_env(:unex, :config_encryption_key),
      "UNEX_DASHBOARD_SECRET" => dashboard_secret_key_base()
    }

    path = Unex.Dev.env_file(data_dir)
    existing = Unex.Dev.read_env_file(path)

    merged =
      Unex.Dev.persisted_vars()
      |> Enum.reduce(existing, fn var, acc ->
        case Map.get(resolved, var) do
          value when is_binary(value) and value != "" -> Map.put(acc, var, value)
          _ -> acc
        end
      end)

    if merged != existing do
      Unex.Dev.write_env_file!(path, merged)
      Mix.shell().info("[unex.dev] credentials for this data dir saved to #{path}")
    end
  end

  defp dashboard_secret_key_base do
    :unex
    |> Application.get_env(Unex.Dashboard.Endpoint, [])
    |> Keyword.get(:secret_key_base)
  end

  defp dashboard_url do
    if Application.get_env(:unex, :start_dashboard, false) do
      "http://localhost:#{Application.get_env(:unex, :dashboard_port)}" <>
        " (basic auth: #{Application.get_env(:unex, :dashboard_username)})"
    end
  end

  defp resolved_dispatcher_path(data_dir) do
    Application.get_env(:unex, :dispatcher_path) || Path.join(data_dir, "dispatcher.uc")
  end

  # --- preflight -----------------------------------------------------------

  defp preflight_ucm! do
    path =
      case Unex.UCM.find() do
        {:ok, path} ->
          path

        {:error, :not_found} ->
          Mix.raise("""
          UCM (the Unison Codebase Manager) is not on PATH.

          Unex evaluates Unison through UCM: deploys spawn it to extract code and
          every dispatcher worker IS a `ucm run.compiled` subprocess. There is no
          local mode without it.

              brew install unisonweb/unison/unison-language

          or see https://www.unison-lang.org/docs/quickstart/ — then set UCM_PATH
          if the binary is not called `ucm`.
          """)
      end

    case Unex.UCM.version() do
      {:ok, release} ->
        {path, release}

      {:error, reason} ->
        Mix.raise("Found UCM at #{path} but could not read its version: #{inspect(reason)}")
    end
  end

  defp preflight_dispatcher!(opts, path, ucm_release) do
    cond do
      opts[:skip_dispatcher] ->
        Mix.shell().info("[unex.dev] --skip-dispatcher: service calls will not work")
        "skipped"

      true ->
        case Unex.Dev.bundle_status(path, ucm_release) do
          {:ok, version} ->
            version

          {:rebuild, reason} ->
            Mix.shell().info(
              "[unex.dev] rebuilding the dispatcher bundle: #{Unex.Dev.explain(reason)}"
            )

            Mix.Task.run("unex.compile_dispatcher", ["--out", path])
            recheck!(path, ucm_release)
        end
    end
  end

  defp recheck!(path, ucm_release) do
    case Unex.Dev.bundle_status(path, ucm_release) do
      {:ok, version} ->
        version

      {:rebuild, reason} ->
        Mix.raise("""
        The dispatcher bundle at #{path} still #{Unex.Dev.explain(reason)} after
        rebuilding it. Service calls would fail with :dispatcher_not_started.

        Run `mix unex.compile_dispatcher --out #{path}` on its own to see UCM's
        output, or pass --skip-dispatcher to start without a dispatcher.
        """)
    end
  end
end
