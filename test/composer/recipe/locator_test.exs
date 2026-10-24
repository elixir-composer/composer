defmodule Composer.Recipe.LocatorTest do
  use ExUnit.Case, async: true

  alias Composer.Recipe.Locator

  @fixture "test/support/fixtures/locator/positions.exs"

  setup do
    {:ok, index} = Locator.index_file(@fixture)
    %{index: index}
  end

  # The source text a one-line range covers.
  defp text(index, {{line, column}, {line, end_column}}),
    do: index |> Locator.line(line) |> String.slice(column - 1, end_column - column)

  test "a ref literal, quotes included", %{index: index} do
    range = Locator.locate(index, "auth", {:ref, "lab:auth/passkeys"})
    assert range == {{12, 7}, {12, 26}}
    assert text(index, range) == ~s("lab:auth/passkeys")
  end

  test "a ref written twice is found at its first occurrence", %{index: index} do
    assert {{12, _}, _} = Locator.locate(index, "auth", {:ref, "lab:auth/passkeys"})
    assert [{{12, _}, _}, {{19, _}, _}] = Locator.refs(index, "auth", "lab:auth/passkeys")
  end

  test "an escaped string covers its source, not its value", %{index: index} do
    range = Locator.locate(index, "auth", {:ref, ~s(esc"aped)})
    assert text(index, range) == ~S("esc\"aped")
  end

  test "a ref built at run time falls back to the steps: key", %{index: index} do
    range = Locator.locate(index, "auth", {:ref, "lab:dynamic"})
    assert range == {{11, 5}, {11, 11}}
    assert text(index, range) == "steps:"
  end

  test "the string of a {ref, opts} entry, and its if: flag", %{index: index} do
    assert text(index, Locator.locate(index, "auth", {:ref, "cb_std:setup/credo"})) ==
             ~s("cb_std:setup/credo")

    assert text(index, Locator.locate(index, "auth", {:if, :credo})) == ":credo"
    # An undeclared flag that is not written falls back to steps:.
    assert text(index, Locator.locate(index, "auth", {:if, :nope})) == "steps:"
  end

  test "a multi-line entry spans its lines", %{index: index} do
    entry = {"hex:igniter", argv: ["--yes"]}
    assert Locator.locate(index, "auth", {:entry, entry}) == {{16, 7}, {17, 24}}
    # An entry that is not literal in the source is found by its first string.
    assert {{16, 8}, _} = Locator.locate(index, "auth", {:entry, {"hex:igniter", argv: [:x]}})
  end

  test "uses, keys and recipe names", %{index: index} do
    assert text(index, Locator.locate(index, "auth", {:use, "base"})) == ~s("base")
    assert text(index, Locator.locate(index, "auth", {:key, :flags})) == "flags:"
    assert text(index, Locator.locate(index, "auth", :recipe)) == "auth:"
    # A key the recipe does not have falls back to its name.
    assert text(index, Locator.locate(index, "auth", {:key, :doc})) == "auth:"
    assert Locator.locate(index, "nope", :recipe) == Locator.first_line()
  end

  test "aliases: and steps: read through top-level bindings", %{index: index} do
    range = Locator.locate(index, "auth", {:alias, :lab})
    assert range == {{2, 12}, {2, 16}}
    assert text(index, range) == "lab:"

    assert text(index, Locator.locate(index, "bound", {:ref, "cb_std:setup/gitignore"})) ==
             ~s("cb_std:setup/gitignore")

    assert {{3, 1}, {3, 7}} = index.bindings[:shared]
  end

  test "alias targets, literal or through a binding", %{index: index} do
    assert Locator.recipe(index, "auth").alias_targets == %{lab: "cc_lab"}
    assert Locator.recipe(index, "base").alias_targets == %{}

    {:ok, index} = Locator.index(~s|[a: [aliases: [x: "one", y: :atom], steps: []]]|, "g.exs")
    assert Locator.recipe(index, "a").alias_targets == %{x: "one"}
  end

  test "columns count characters after non-ASCII text", %{index: index} do
    range = Locator.locate(index, "base", {:ref, "cb_std:setup/sort_deps"})
    assert text(index, range) == ~s("cb_std:setup/sort_deps")
    assert text(index, Locator.locate(index, "base", {:use, "bound"})) == ~s("bound")
    assert text(index, Locator.locate(index, "base", {:if, :x})) == ":x"
  end

  test "cursor lookups agree with forward lookups", %{index: index} do
    for recipe <- index.recipes do
      ranges =
        [{:recipe, recipe.name, recipe.key}] ++
          for({key, range} <- recipe.keys, do: {:key, key, range}) ++
          for({string, range} <- recipe.refs, do: {:ref, string, range}) ++
          for({string, range} <- recipe.uses, do: {:use, string, range}) ++
          for({name, range} <- recipe.aliases, do: {:alias, name, range})

      for {kind, value, {{line, column}, _} = range} <- ranges do
        assert {^kind, _recipe, ^value, ^range} = Locator.at(index, line, column)
      end
    end

    assert {:ref, "auth", "cb_std:setup/credo", _} = Locator.at(index, 13, 10)
    assert Locator.at(index, 1, 1) == nil
  end

  test "a source that does not parse is an error, with its line" do
    assert {:error, {:group_parse, "x.exs", _description, 1}} =
             Locator.index("[a: [steps: [\"x\"]", "x.exs")
  end
end
