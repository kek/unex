defmodule Unex.Dashboard.UnisonHighlightTest do
  use ExUnit.Case, async: true

  alias Unex.Dashboard.UnisonHighlight

  describe "to_html/2 token classes" do
    test "highlights keywords" do
      html = UnisonHighlight.to_html("type Foo = Bar")
      assert html =~ ~s(<span class="unison-keyword">type</span>)
    end

    test "highlights the ability / match / cases / do / let / use keywords" do
      for kw <- ~w(ability match cases do let use handle) do
        html = UnisonHighlight.to_html(kw)

        assert html =~ ~s(<span class="unison-keyword">#{kw}</span>),
               "expected #{kw} to be a keyword span, got: #{html}"
      end
    end

    test "highlights type / constructor names (uppercase-initial) as types" do
      html = UnisonHighlight.to_html("Optional")
      assert html =~ ~s(<span class="unison-type">Optional</span>)
    end

    test "highlights string literals" do
      html = UnisonHighlight.to_html(~s(greet = "hello world"))
      assert html =~ ~s(<span class="unison-string">&quot;hello world&quot;</span>)
    end

    test "highlights number literals" do
      html = UnisonHighlight.to_html("x = 42")
      assert html =~ ~s(<span class="unison-number">42</span>)
    end

    test "highlights line comments" do
      html = UnisonHighlight.to_html("-- a comment")
      assert html =~ ~s(<span class="unison-comment">-- a comment</span>)
    end

    test "highlights block comments" do
      html = UnisonHighlight.to_html("{- block -}")
      assert html =~ ~s(<span class="unison-comment">{- block -}</span>)
    end

    test "highlights operators including -> and :" do
      html = UnisonHighlight.to_html("f : Nat -> Nat")
      assert html =~ ~s(<span class="unison-operator">-&gt;</span>)
      assert html =~ ~s(<span class="unison-operator">:</span>)
    end

    test "lowercase identifiers are not keywords or types" do
      html = UnisonHighlight.to_html("greeting")
      refute html =~ "unison-keyword"
      refute html =~ "unison-type"
    end
  end

  describe "to_html/2 safety and fidelity" do
    test "HTML-escapes source so code is never injected raw" do
      html = UnisonHighlight.to_html(~s(x = "<script>&"))
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "&amp;"
    end

    test "round-trips the visible text without dropping or mangling code" do
      source = """
      structural type Optional a = None | Some a

      -- greet someone
      greet : Text -> Text
      greet name =
        use Text ++
        "Hello, " ++ name
      """

      html = UnisonHighlight.to_html(source)
      # Stripping all tags must recover the original (HTML-unescaped) source.
      recovered =
        html
        |> String.replace(~r/<[^>]*>/, "")
        |> unescape()

      assert recovered == source
    end
  end

  describe "to_html/2 with :link option" do
    test "wraps linkable identifiers in an anchor carrying the token class" do
      link = fn
        "greet" -> "/dashboard/nonode/hash?id=abc"
        _ -> nil
      end

      html = UnisonHighlight.to_html("greet name", link: link)

      assert html =~
               ~s(<a href="/dashboard/nonode/hash?id=abc" class="unison-ref">greet</a>)

      # non-linked identifier stays plain text
      assert html =~ "name"
      refute html =~ ~s(<a href="/dashboard/nonode/hash?id=abc" class="unison-ref">name</a>)
    end

    test "links type names too, keeping the type class on the anchor" do
      link = fn
        "Optional" -> "/hash?id=def"
        _ -> nil
      end

      html = UnisonHighlight.to_html("Optional", link: link)
      assert html =~ ~s(<a href="/hash?id=def" class="unison-ref unison-type">Optional</a>)
    end
  end

  defp unescape(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end
end
