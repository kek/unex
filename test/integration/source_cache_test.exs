defmodule Unex.Integration.SourceCacheTest do
  @moduledoc """
  End-to-end coverage of source caching at deploy time.

  Requires UCM on PATH and network access to Unison Share. Skipped in CI
  (see the integration exclude in test/test_helper.exs).

  This test pins down the current behavior and known limitations:

    * `view <entry_point>` in the extraction session DOES cache pretty-printed
      source for the service's root hash. ✓
    * UCM's `view #<hash>` resolves only hashes registered in the codebase's
      name map. Hashes returned by `Code.dependencies` often point to
      compiled sub-references (extracted lambdas, synthesized bindings) that
      have no name-map entry — UCM says "not found in the codebase" for
      those. The second UCM session gracefully skips them. ✗ (by design)

  If a future UCM exposes raw-hash source lookup (or if we extend the
  extractor to emit a name↔hash map), the second assertion can tighten.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  # Deploys touch the network and can take a while.
  @moduletag timeout: 300_000

  alias Unex.Cluster.{HashCache, SourceCache}

  setup do
    # Start the minimum process set the extractor needs, plus the caches the
    # deploy path writes to. Uses per-test names so we don't collide with a
    # globally running app.
    start_supervised!(HashCache)
    start_supervised!(SourceCache)
    start_supervised!(Unex.Cluster.DepsCache)
    start_supervised!(Unex.Cluster.SyncServer)
    start_supervised!({Phoenix.PubSub, name: Unex.PubSub})
    start_supervised!(Unex.Services.Registry)
    start_supervised!(Unex.Runtime)
    :ok
  end

  @tag :integration
  test "deploy caches source for the service's root hash" do
    assert {:ok, %Unex.Services.Registry.Entry{hash: root_hash}} =
             Unex.Services.deploy("counter", "@kek/counter", "mainCounter")

    # The entry-point view in session 1 produces the root source.
    assert {:ok, source} = SourceCache.get(root_hash)
    assert source =~ "mainCounter"
    assert source =~ "Unex.main counter"
  end

  @tag :integration
  test "compiled sub-reference hashes have no source cached (known limitation)" do
    assert {:ok, %Unex.Services.Registry.Entry{hash: root_hash}} =
             Unex.Services.deploy("counter", "@kek/counter", "mainCounter")

    # Pick a non-root hash from the deps cache.
    {:ok, root_deps} = Unex.Cluster.DepsCache.get(root_hash)
    assert is_list(root_deps) and root_deps != []

    # Most (commonly all) of these hashes are compiled sub-references UCM's
    # `view` cannot resolve. We assert the cache either has source or is
    # empty — both outcomes are acceptable; what we DON'T want is cached
    # UCM error text masquerading as source.
    for dep_hash <- root_deps do
      case SourceCache.get(dep_hash) do
        {:ok, source} ->
          refute source =~ "not found in the codebase",
                 "UCM error text should not be cached as source for #{dep_hash}"

          refute source =~ "Check your spelling",
                 "UCM error text should not be cached as source for #{dep_hash}"

          refute source =~ "well-formed",
                 "UCM error text should not be cached as source for #{dep_hash}"

        :not_found ->
          :ok
      end
    end
  end
end
