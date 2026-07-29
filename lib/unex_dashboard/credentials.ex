defmodule Unex.Dashboard.Credentials do
  @moduledoc """
  Resolves the dashboard's HTTP Basic Auth credentials and the endpoint's
  `secret_key_base` from already-resolved configuration values.

  This lives in a module rather than inline in `config/runtime.exs` so the
  production rules are testable. `runtime.exs` resolves env vars and the
  optional config file, hands the result here, and applies what comes back.

  The rule is asymmetric on purpose:

    * `:dev` / `:test` — fall back to the documented `admin` / `unex` pair, so
      `mix run --no-halt` and `mix test` need no setup.
    * `:prod` with the dashboard enabled — the credentials must be configured
      explicitly. There is no fallback: `resolve!/2` raises rather than serve
      the ops dashboard behind a publicly guessable login.
    * `:prod` with the dashboard disabled — returns `{nil, nil}`, so the
      development defaults compiled into `config/config.exs` are not left
      sitting in application config where a production node could reach them.
      `Unex.Dashboard.BasicAuth` fails closed on unset credentials.
  """

  @default_username "admin"
  @default_password "unex"

  # Passwords that this repo, its README, or its docs hand out. A deployment
  # using one of these is effectively unauthenticated, whether the value
  # arrived from the compiled-in default or was typed into a config file.
  @known_insecure_passwords [@default_password, "admin", "password", "changeme", "secret"]

  @doc "The username used in dev and test."
  def default_username, do: @default_username

  @doc "The password used in dev and test."
  def default_password, do: @default_password

  @doc "Passwords rejected on the production path."
  def known_insecure_passwords, do: @known_insecure_passwords

  @doc """
  Resolves `{username, password}` for `env`.

  Options:

    * `:username`, `:password` — values resolved from env vars or the config
      file. `nil` (or blank) means "not configured".
    * `:dashboard_enabled?` — whether the dashboard subsystem will be started.

  Raises `RuntimeError` on the production path when the dashboard is enabled
  but the credentials are missing or are one of the shipped defaults.
  """
  def resolve!(env, opts \\ [])

  def resolve!(:prod, opts) do
    username = opts |> Keyword.get(:username) |> presence()
    password = opts |> Keyword.get(:password) |> presence()

    cond do
      not Keyword.get(opts, :dashboard_enabled?, false) ->
        {nil, nil}

      is_nil(username) or is_nil(password) ->
        raise missing_credentials_message(username, password)

      password in @known_insecure_passwords ->
        raise insecure_password_message()

      true ->
        {username, password}
    end
  end

  def resolve!(_env, opts) do
    {opts |> Keyword.get(:username) |> presence() || @default_username,
     opts |> Keyword.get(:password) |> presence() || @default_password}
  end

  @doc """
  Resolves the dashboard endpoint's `secret_key_base`.

  Returns `{value, generated?}`, mirroring
  `Unex.ConfigResolver.resolve_encryption_key/1`. When nothing is configured a
  random value is generated: it signs dashboard session cookies, so a value
  derived from public information (the app name, the node name) would be
  forgeable by anyone who can read this repository. Regenerating it per boot
  only costs already-issued dashboard sessions.
  """
  def resolve_secret_key_base(configured) do
    case presence(configured) do
      nil -> {Base.encode64(:crypto.strong_rand_bytes(48)), true}
      value -> {value, false}
    end
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp missing_credentials_message(username, password) do
    missing =
      [{username, "UNEX_DASHBOARD_USER"}, {password, "UNEX_DASHBOARD_PASS"}]
      |> Enum.filter(fn {value, _var} -> is_nil(value) end)
      |> Enum.map(fn {_value, var} -> var end)

    """
    The Unex dashboard is enabled in production but its Basic Auth credentials \
    are not configured: #{Enum.join(missing, " and ")} #{verb(missing)} unset.

    Refusing to boot. Starting anyway would put the built-in development login \
    (#{@default_username} / #{@default_password}) in front of the ops dashboard.

    Set both:

        UNEX_DASHBOARD_USER=<username>
        UNEX_DASHBOARD_PASS=<a strong, unique password>

    They can also be set as `dashboard_username:` / `dashboard_password:` in the \
    Unex config file (`$UNEX_CONFIG`, `~/.config/unex/config.exs`, or \
    `/etc/unex/config.exs`).

    To run without the dashboard instead, unset UNEX_DASHBOARD.
    """
  end

  defp insecure_password_message do
    """
    The Unex dashboard is enabled in production but UNEX_DASHBOARD_PASS is one \
    of the passwords published in this repository and its documentation \
    (#{Enum.map_join(@known_insecure_passwords, ", ", &inspect/1)}).

    Refusing to boot. Set UNEX_DASHBOARD_PASS to a strong, unique password \
    (for example: `openssl rand -base64 24`).
    """
  end

  defp verb([_one]), do: "is"
  defp verb(_many), do: "are"
end
