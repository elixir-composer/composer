defmodule Composer.LSP.HoverTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.{Cursor, Hover, Lookup}
  alias Composer.Test.LSPFixtures

  @moduletag :tmp_dir

  @host %{project: "host_app", root: "/src/host_app"}
  @footer "_composer-ls · host: host_app (/src/host_app)_"

  setup %{tmp_dir: dir} do
    {snapshot, path} = LSPFixtures.workspace(dir)

    hover = fn line, column ->
      LSPFixtures.app_source()
      |> Cursor.at(path, line, column)
      |> Lookup.resolve(path, snapshot)
      |> Hover.render(@host, Lookup.cookbooks(snapshot))
    end

    %{hover: hover}
  end

  test "a step: its metadata table", %{hover: hover} do
    text = hover.(8, 8)
    assert text =~ "**fake_book:hello** - Writes hello.txt"
    assert text =~ "| action | gen |"
    assert text =~ "| module | Composer.FakeBook.Steps.Hello |"
    assert String.ends_with?(text, @footer)
  end

  test "a recipe: shortdoc, doc, flags and entries", %{hover: hover} do
    text = hover.(12, 9)
    assert text =~ "**mine/app/base** - Base"
    assert text =~ "The base."
    assert text =~ "- `--x` - An x"
    assert text =~ "1. cb_std:setup:gitignore"
    assert String.ends_with?(text, @footer)
  end

  test "hex:, in step.show's wording, and a bare word's error", %{hover: hover} do
    explicit = hover.(10, 8)
    assert explicit =~ "hex:oban - the Hex package oban"
    assert String.ends_with?(explicit, @footer)

    bare = hover.(11, 8)
    assert bare =~ ~s("oban" is not an address; write "hex:oban")
    assert String.ends_with?(bare, @footer)
  end

  test "an alias: its target cookbook", %{hover: hover} do
    text = hover.(1, 13)
    assert text =~ "`fb` is an alias for cookbook `fake_book`"
    assert String.ends_with?(text, @footer)
  end

  test "a reference that does not resolve: the error", %{hover: hover} do
    text = hover.(14, 8)
    assert text =~ "nope"
    assert String.ends_with?(text, @footer)
  end

  test "nothing to show" do
    assert Hover.render(nil, @host) == nil
  end
end
