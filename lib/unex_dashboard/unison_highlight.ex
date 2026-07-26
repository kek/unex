defmodule Unex.Dashboard.UnisonHighlight do
  @moduledoc false
  # Minimal, dependency-free syntax highlighter for pretty-printed Unison
  # source shown in the dashboard hash view. There is no Makeup lexer for
  # Unison, so this tokenizes the source with a small ordered rule set and
  # renders each token as an HTML-escaped `<span class="unison-…">`.
  #
  # It is intentionally conservative: it never drops or reorders characters,
  # so stripping the emitted tags recovers the original source verbatim. When
  # a `:link` function is supplied, identifier/type tokens that resolve to a
  # URL are wrapped in an `<a class="unison-ref …">` instead (this is how the
  # hash page keeps its name → hash navigation while adding colour).

  @keywords ~w(
    type ability structural unique match cases with where do let handle
    if then else forall use namespace termLink typeLink and or true false
  )

  # Ordered token rules. Each pattern is anchored at the current position
  # (`\A`); the first match wins. Anything not matched by a rule is emitted as
  # a run of plain (unclassified) text, so the tokenizer is total.
  @rules [
    {:comment, ~r/\A\{-.*?-\}/s},
    {:doc, ~r/\A\{\{.*?\}\}/s},
    {:comment, ~r/\A--[^\n]*/},
    {:string, ~r/\A"(?:\\.|[^"\\])*"/},
    {:string, ~r/\A\?\\?./s},
    {:number, ~r/\A[0-9][0-9_]*(?:\.[0-9]+)?/},
    {:hash, ~r/\A#[A-Za-z0-9_]+/},
    {:ident, ~r/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*/},
    {:operator, ~r{\A(?:->|<-|=>|::|==|!=|<=|>=|&&|\|\||\+\+|[|=+\-*/<>&^%!'@\\:.])}}
  ]

  @doc """
  Render Unison `source` to highlighted HTML.

  Options:
    * `:link` — a 1-arity function taking an identifier/type token string and
      returning a URL string to link it to, or `nil` for no link.
  """
  @spec to_html(binary, keyword) :: binary
  def to_html(source, opts \\ []) when is_binary(source) do
    link = Keyword.get(opts, :link, fn _ -> nil end)

    source
    |> tokenize()
    |> Enum.map(&render_token(&1, link))
    |> IO.iodata_to_binary()
  end

  # ---- tokenizer ------------------------------------------------------------

  # Returns a list of {class :: atom, text :: binary} tuples covering the whole
  # input in order. `:plain` marks unclassified text (whitespace, punctuation).
  defp tokenize(source), do: tokenize(source, [])

  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize(rest, acc) do
    case match_rule(rest) do
      {class, matched, tail} ->
        tokenize(tail, [{class, matched} | acc])

      :no_match ->
        # Consume a single character as plain text and keep going. Adjacent
        # plain characters stay separate tuples; render_token escapes each,
        # which is fine for correctness (and cheap for typical source sizes).
        <<c::utf8, tail::binary>> = rest
        tokenize(tail, [{:plain, <<c::utf8>>} | acc])
    end
  end

  defp match_rule(rest), do: match_rule(@rules, rest)

  defp match_rule([], _rest), do: :no_match

  defp match_rule([{class, regex} | tail], rest) do
    case Regex.run(regex, rest, return: :index) do
      [{0, len}] ->
        matched = binary_part(rest, 0, len)
        remaining = binary_part(rest, len, byte_size(rest) - len)
        {classify(class, matched), matched, remaining}

      _ ->
        match_rule(tail, rest)
    end
  end

  # An `:ident` match is refined into a keyword, a type (uppercase initial),
  # or a plain identifier.
  defp classify(:ident, token) do
    cond do
      token in @keywords -> :keyword
      uppercase_initial?(token) -> :type
      true -> :ident
    end
  end

  defp classify(class, _token), do: class

  defp uppercase_initial?(<<c, _::binary>>) when c in ?A..?Z, do: true
  defp uppercase_initial?(_), do: false

  # ---- rendering ------------------------------------------------------------

  # Identifier and type tokens may be linked; everything else is a span (or
  # bare escaped text for :plain).
  defp render_token({class, text}, link) when class in [:ident, :type] do
    case safe_link(link, text) do
      nil -> span(class, text)
      url -> anchor(url, class, text)
    end
  end

  defp render_token({:plain, text}, _link), do: escape(text)
  defp render_token({class, text}, _link), do: span(class, text)

  defp safe_link(link, text) do
    case link.(text) do
      url when is_binary(url) -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp span(:ident, text), do: [~s(<span class="unison-ident">), escape(text), "</span>"]

  defp span(class, text),
    do: [~s(<span class="unison-), class_name(class), ~s(">), escape(text), "</span>"]

  # A linked identifier keeps its class on the anchor so it is coloured like a
  # type/name and clearly navigable. Plain identifiers get just `unison-ref`.
  defp anchor(url, :type, text) do
    [~s(<a href="), escape(url), ~s(" class="unison-ref unison-type">), escape(text), "</a>"]
  end

  defp anchor(url, _class, text) do
    [~s(<a href="), escape(url), ~s(" class="unison-ref">), escape(text), "</a>"]
  end

  defp class_name(class), do: Atom.to_string(class)

  defp escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
