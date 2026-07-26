defmodule Unex.Dashboard.HashHighlightTest do
  # Renders the real dashboard hash page for a hash with cached Unison source
  # and proves the source comes back syntax-highlighted (token spans) rather
  # than as a plain, unhighlighted blob.
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias Unex.Cluster.NameCache
  alias Unex.Cluster.SourceCache

  @creds Base.encode64("admin:unex")

  @snippet """
  structural type Optional a = None | Some a

  -- greet a name
  greet : Text -> Text
  greet name =
    "Hello, " ++ name
  """

  setup do
    Application.put_env(:unex, :dashboard_username, "admin")
    Application.put_env(:unex, :dashboard_password, "unex")

    start_supervised!(Unex.Dashboard.Endpoint)
    # Caches are started by the application; keep them clean for this test.
    SourceCache.clear()
    NameCache.clear()

    on_exit(fn ->
      SourceCache.clear()
      NameCache.clear()
    end)

    :ok
  end

  defp authed_get(path) do
    build_conn(:get, path)
    |> put_req_header("authorization", "Basic #{@creds}")
    |> Unex.Dashboard.Endpoint.call(Unex.Dashboard.Endpoint.init([]))
  end

  test "cached Unison source renders with highlight token markup" do
    hash = "#abcdef0123456789"
    SourceCache.put(hash, @snippet)
    # Make `greet` a navigable name → hash reference to exercise linking too.
    NameCache.put("#deadbeef", "greet")

    node_seg = URI.encode_www_form(Atom.to_string(node()))
    conn = authed_get("/dashboard/#{node_seg}/hash?id=#{URI.encode_www_form(hash)}")

    assert conn.status == 200
    body = conn.resp_body

    # The source card is present with highlighted keyword and type spans.
    assert body =~ ~s(<span class="unison-keyword">type</span>)
    assert body =~ ~s(<span class="unison-type">Optional</span>)
    assert body =~ ~s(<span class="unison-string">)
    assert body =~ ~s(<span class="unison-comment">)
    assert body =~ ~s(<span class="unison-operator">-&gt;</span>)
    # The known name is linked (navigation preserved on top of highlighting).
    assert body =~ ~s(class="unison-ref">greet</a>)
    # Scoped styles were emitted.
    assert body =~ "pre.unison-src .unison-keyword"
  end
end
