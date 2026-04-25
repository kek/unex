defmodule Unex.Integration.SourceCacheTest do
  @moduledoc """
  End-to-end coverage of source caching at deploy time.

  Requires UCM on PATH and network access to Unison Share. Skipped in CI.

  Drives the source-caching pipeline against the real `@kek/counter` project
  and asserts that named terms used by the deploy actually have source
  cached.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  alias Unex.Cluster.{HashCache, SourceCache, DepsCache, NameCache}

  # Stable content-addressed hashes for terms in @kek/counter (verified by
  # running `Link.Term.toText (termLink <name>)` in UCM on this codebase).
  @counter_hash "0176dnkj6i2cv4ro6nc620mi0ohflnool5komk8huedoeoa5jaic8"
  @unex_main_hash "00hhl2tuqd3sq7ben43c3jg78qsphnokb8kec4mvgbsodtu793qcg"

  setup do
    assert is_pid(Process.whereis(HashCache))
    assert is_pid(Process.whereis(SourceCache))
    assert is_pid(Process.whereis(DepsCache))
    assert is_pid(Process.whereis(NameCache))
    SourceCache.clear()
    NameCache.clear()
    :ok
  end

  describe "deploying @kek/counter caches source for named terms" do
    setup do
      assert {:ok, %Unex.Services.Registry.Entry{hash: root_hash}} =
               Unex.Services.deploy("counter", "@kek/counter", "mainCounter")

      %{root_hash: root_hash}
    end

    test "root hash gets entry-point source", %{root_hash: root_hash} do
      assert {:ok, source} = SourceCache.get(root_hash)
      assert source =~ "mainCounter"
      assert source =~ "Unex.main counter"
    end

    test "project-local term `counter` has source cached" do
      assert {:ok, source} = SourceCache.get(@counter_hash)
      assert source =~ "counter"
      # The counter function uses Storage to track hits — source should
      # mention the relevant ability calls.
      assert source =~ "createDatabase" or source =~ "writeCell" or source =~ "html"
    end

    test "lib term `lib.kek_unex_0_1_1.Unex.main` has source cached" do
      assert {:ok, source} = SourceCache.get(@unex_main_hash)
      assert source =~ "Unex.main"
    end

    test "named-term hashes get a name in NameCache" do
      assert {:ok, counter_name} = NameCache.get(@counter_hash)
      assert counter_name =~ "counter"

      assert {:ok, unex_main_name} = NameCache.get(@unex_main_hash)
      assert unex_main_name =~ "Unex.main"
    end
  end
end
