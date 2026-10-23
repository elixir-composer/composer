defmodule Composer.LSP.DefinitionTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.{Cursor, Definition, Lookup}
  alias Composer.Test.LSPFixtures

  @positions "test/support/fixtures/locator/positions.exs"

  @tag :tmp_dir
  test "a step: its source, at use Composer.Step", %{tmp_dir: dir} do
    {snapshot, path} = LSPFixtures.workspace(dir)
    result = LSPFixtures.app_source() |> Cursor.at(path, 8, 8) |> Lookup.resolve(path, snapshot)

    assert {source, {{2, 3}, {2, 20}}} = Definition.target(result, snapshot.cookbooks, %{})
    assert String.ends_with?(source, "fake_book/steps/hello.ex")
  end

  @tag :tmp_dir
  test "a recipe: its key in its group file", %{tmp_dir: dir} do
    {snapshot, path} = LSPFixtures.workspace(dir)
    result = LSPFixtures.app_source() |> Cursor.at(path, 13, 15) |> Lookup.resolve(path, snapshot)

    assert {group, {{8, 3}, {8, 8}}} = Definition.target(result, snapshot.cookbooks, %{})
    assert String.ends_with?(group, "fake_book/recipes/main.exs")
  end

  test "an alias bound to a top-level variable: the binding's entry" do
    text = File.read!(@positions)
    buffer = %{text: text, path: @positions, recipe: "auth"}

    assert Definition.target({:alias, "lab", "cc_lab"}, [], buffer) ==
             {@positions, {{2, 12}, {2, 16}}}
  end

  test "hex: links, in parsing and non-parsing buffers" do
    text = File.read!(@positions)
    url = "https://hexdocs.pm/igniter"

    assert Definition.links(text, @positions) == [{{{16, 8}, {16, 21}}, url}]
    assert Definition.links(text <> "\n[", @positions) == [{{{16, 8}, {16, 21}}, url}]
    assert Definition.hexdocs("hex:acme.secret") == "https://acme.hexdocs.pm/secret"
    assert Definition.hexdocs("core:x") == nil
  end
end
