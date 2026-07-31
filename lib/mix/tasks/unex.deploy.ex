defmodule Mix.Tasks.Unex.Deploy do
  @moduledoc """
  Deploys a Unison program to a running Unex node — from a local `.u` file, with
  no Unison Share round trip.

      mix unex.deploy ./counter.u mainCounter --as counter
      mix unex.deploy ./counter.u mainCounter          # --as defaults to "counter"
      mix unex.deploy --project @kek/counter mainCounter --as counter

  This is slice 2 of `docs/local-dev.md`: the edit → deploy → look loop without
  the two network hops. It is an HTTP client and nothing more — it POSTs to the
  same `POST /services/:name/deploy` endpoint the Unison `Unex.Services.deploy`
  ability posts to, with the file's text in a `source` field instead of a
  `project` field. The server ingests it with `load` + `update` instead of
  `pull` and then runs *the same* extractor over *the same* codebase, so a local
  deploy mints the same root hash a Share deploy of the same code would.

  `--project` deploys from Unison Share instead, unchanged. Local deploys are a
  superset, not a replacement.

  ## What it costs

  Deploying from a file skips the dashboard source-capture stages by default.
  On this bench they were 95 s of a 101 s deploy and they change nothing about
  the deployed bytes — see `Unex.Runtime.capture_source?/2`. Pass
  `--capture-source` to spend the time and get a fully populated `/hash/:id`
  page; `--no-capture-source` forces it off for a Share deploy too.

  ## Finding the node

  In the common case, nothing needs to be passed: `mix unex.dev` writes the
  generated `UNEX_SECRET` into `<data-dir>/dev.env`, and this task reads it back
  from the same place via `Unex.Dev.data_dir/1`. Explicit flags and the ordinary
  `UNEX_*` variables win over it.

  Options:

    * `--as NAME` — service name. Defaults to the `.u` file's basename;
      required with `--project`.
    * `--project PROJECT` — deploy from Unison Share instead of a file.
    * `--url URL` — node base URL. Defaults to `UNEX_URL`, else
      `http://localhost:$UNEX_PORT` (4040).
    * `--secret SECRET` — bearer token. Defaults to `UNEX_SECRET`, else the
      `dev.env` in the data directory.
    * `--data PATH` — data directory to read `dev.env` from.
    * `--capture-source` / `--no-capture-source` — override source capture.
    * `--timeout MS` — HTTP timeout. Defaults to 600000, matching the server's
      own deploy timeout.

  See `docs/local-dev.md`.
  """

  use Mix.Task

  @shortdoc "Deploy a local .u file to a running Unex node"

  @switches [
    as: :string,
    project: :string,
    url: :string,
    secret: :string,
    data: :string,
    capture_source: :boolean,
    timeout: :integer
  ]

  @default_timeout 600_000

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("unrecognized options: #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    # Compile so `Unex.Dev` is available. Deliberately no `app.config` and no
    # `app.start`: this task talks to a node over HTTP, it does not become one.
    Mix.Task.run("compile")

    {origin, entry_point, service} = parse_target(opts, args)
    {url, secret} = resolve_node(opts)

    Mix.shell().info(describe(origin, entry_point, service, url, opts))

    body = Jason.encode!(request_body(origin, entry_point, opts))
    started = System.monotonic_time(:millisecond)

    result =
      post_json(
        "#{url}/services/#{URI.encode(service)}/deploy",
        secret,
        body,
        opts[:timeout] || @default_timeout
      )

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, 200, response} ->
        report_success(Jason.decode!(response), service, url, elapsed)

      {:ok, status, response} ->
        Mix.raise("deploy failed (HTTP #{status}) after #{seconds(elapsed)}s:\n#{response}")

      {:error, reason} ->
        Mix.raise("""
        could not reach #{url}: #{inspect(reason)}

        Is a node running? Start one with `mix unex.dev`.
        """)
    end
  end

  # --- arguments -----------------------------------------------------------

  defp parse_target(opts, args) do
    case {opts[:project], args} do
      {nil, [file, entry_point]} ->
        path = Path.expand(file)

        unless File.regular?(path), do: Mix.raise("no such file: #{path}")

        unless Path.extname(path) == ".u" do
          Mix.raise("expected a Unison source file ending in .u, got #{path}")
        end

        {{:file, path}, entry_point, opts[:as] || Path.basename(path, ".u")}

      {project, [entry_point]} when is_binary(project) ->
        service =
          opts[:as] ||
            Mix.raise("--as NAME is required when deploying from --project")

        {{:share, project}, entry_point, service}

      _ ->
        Mix.raise("""
        Usage:

            mix unex.deploy <file.u> <entry-point> [--as NAME]
            mix unex.deploy --project <project> <entry-point> --as NAME

        The entry point must be a thunk: `'{IO, Exception} ()`.
        """)
    end
  end

  defp request_body({:file, path}, entry_point, opts) do
    %{"entry" => entry_point, "source" => File.read!(path)}
    |> put_capture_source(opts)
  end

  defp request_body({:share, project}, entry_point, opts) do
    %{"entry" => entry_point, "project" => project}
    |> put_capture_source(opts)
  end

  defp put_capture_source(body, opts) do
    case opts[:capture_source] do
      flag when is_boolean(flag) -> Map.put(body, "capture_source", flag)
      _ -> body
    end
  end

  # --- the node ------------------------------------------------------------

  # No new configuration language: an explicit flag, then the ordinary UNEX_*
  # environment, then the `dev.env` that `mix unex.dev` persisted in the data
  # directory. `Unex.Dev.data_dir/1` decides where that is, so both tasks agree.
  defp resolve_node(opts) do
    persisted =
      opts[:data]
      |> Unex.Dev.data_dir()
      |> Unex.Dev.env_file()
      |> Unex.Dev.read_env_file()

    url =
      opts[:url] || System.get_env("UNEX_URL") ||
        "http://localhost:#{System.get_env("UNEX_PORT") || 4040}"

    secret =
      opts[:secret] || System.get_env("UNEX_SECRET") || persisted["UNEX_SECRET"] ||
        Mix.raise("""
        No API secret. A Unex node requires `Authorization: Bearer <secret>` on
        every route except /health.

        Pass --secret, export UNEX_SECRET, or run the node with `mix unex.dev`,
        which writes the secret it generated into <data-dir>/dev.env.
        """)

    {String.trim_trailing(url, "/"), secret}
  end

  # Mix prunes the code path to the project's dependency tree, so `:inets` is
  # loadable but not *on the path* — `httpc` resolves and then dies looking for
  # `:http_util`. `Mix.ensure_application!/1` adds it properly. It stays out of
  # `mix.exs` deliberately: the server has no use for an HTTP client, and this
  # task is not part of the release.
  defp post_json(url, secret, body, timeout) do
    Mix.ensure_application!(:inets)
    Mix.ensure_application!(:ssl)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {
      String.to_charlist(url),
      [{~c"authorization", String.to_charlist("Bearer " <> secret)}],
      ~c"application/json",
      body
    }

    case :httpc.request(
           :post,
           request,
           [timeout: timeout, connect_timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- output --------------------------------------------------------------

  defp describe(origin, entry_point, service, url, opts) do
    """
    [unex.deploy] node     #{url}
    [unex.deploy] source   #{origin_line(origin)}
    [unex.deploy] entry    #{entry_point}
    [unex.deploy] service  #{service}
    [unex.deploy] capture  #{capture_line(origin, opts)}
    """
  end

  defp origin_line({:file, path}), do: "#{path} (loaded into the node's codebase)"
  defp origin_line({:share, project}), do: "#{project} (pulled from Unison Share)"

  # Says out loud what the node is about to decide, rather than letting a 95 s
  # difference in deploy time be a mystery. The server owns the decision; this
  # asks the same function for it.
  defp capture_line(origin, opts) do
    on? = Unex.Runtime.capture_source?(origin, Keyword.take(opts, [:capture_source]))

    suffix =
      cond do
        is_boolean(opts[:capture_source]) -> " (explicit)"
        on? -> " (default for a Share deploy; --no-capture-source to skip it)"
        true -> " (default for a file deploy; --capture-source to populate /hash/:id)"
      end

    "dashboard source capture #{if on?, do: "on", else: "off"}#{suffix}"
  end

  defp report_success(%{"hash" => hash}, service, url, elapsed) do
    Mix.shell().info("""

    deployed #{service} in #{seconds(elapsed)}s
      root hash  #{hash}

      curl -s #{url}/#{service}

    Roll back to this exact hash later with:

      curl -s -X POST #{url}/services/#{service}/release \\
        -H "Authorization: Bearer $UNEX_SECRET" \\
        -H 'content-type: application/json' \\
        -d '{"hash":"#{hash}"}'
    """)
  end

  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1)
end
