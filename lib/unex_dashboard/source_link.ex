defmodule Unex.Dashboard.SourceLink do
  @moduledoc """
  Builds external source-browser URLs for a deployed service, given its
  `project` string (as used by `ucm pull`) and `entry_point` name.

  Supports:

    - `@user/proj` or `@user/proj/branch` → Unison Share
    - `@user/proj@hash` variants → treated as Share
    - Anything else → `nil`

  Returns a map `%{host: String.t(), url: String.t()}` or `nil`.
  """

  @share_host "share.unison-lang.org"

  def build(nil, _entry), do: nil
  def build(_project, nil), do: nil

  def build(project, entry_point) when is_binary(project) and is_binary(entry_point) do
    case parse_share(project) do
      {:ok, owner, proj, branch} ->
        path =
          "/#{owner}/#{proj}/code/#{branch}/latest/terms/#{URI.encode(entry_point)}"

        %{host: "Unison Share", url: "https://#{@share_host}#{path}"}

      :error ->
        nil
    end
  end

  # Matches "@user/proj", "@user/proj/branch". Drops any "@hash" suffix.
  defp parse_share("@" <> rest) do
    rest
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.split("/", parts: 3)
    |> case do
      [owner, proj] -> {:ok, "@" <> owner, proj, "main"}
      [owner, proj, branch] -> {:ok, "@" <> owner, proj, branch}
      _ -> :error
    end
  end

  defp parse_share(_), do: :error
end
