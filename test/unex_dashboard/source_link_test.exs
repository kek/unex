defmodule Unex.Dashboard.SourceLinkTest do
  use ExUnit.Case, async: true

  alias Unex.Dashboard.SourceLink

  test "returns nil when project is missing" do
    assert SourceLink.build(nil, "foo") == nil
  end

  test "returns nil when entry_point is missing" do
    assert SourceLink.build("@kek/counter", nil) == nil
  end

  test "builds a Share URL with default main branch" do
    link = SourceLink.build("@kek/counter", "mainCounter")
    assert link.host == "Unison Share"

    assert link.url ==
             "https://share.unison-lang.org/@kek/counter/code/main/latest/terms/mainCounter"
  end

  test "respects an explicit branch segment" do
    link = SourceLink.build("@kek/counter/experiments", "mainCounter")
    assert link.url =~ "/code/experiments/"
  end

  test "ignores a @hash suffix on the project" do
    link = SourceLink.build("@kek/counter@abc123", "mainCounter")
    assert link.url =~ "/@kek/counter/"
    refute link.url =~ "abc123"
  end

  test "returns nil for non-@-prefixed project strings" do
    assert SourceLink.build("kek/counter", "mainCounter") == nil
  end
end
