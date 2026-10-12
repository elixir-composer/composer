defmodule Composer.LSP.CompleteTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.{Complete, Cursor}

  @entries [
    {"cookbook", "fake_book", "A fixture cookbook"},
    {"step", "fake_book:hello", "Writes hello.txt"},
    {"recipe", "fake_book:main/base", "The base recipe"},
    {"group", "fake_book:main/", "2 recipes"}
  ]

  # Does not parse: completion works by line scan.
  @source """
  [
    app: [
      shortdoc: "App",
      aliases: [fb: "fake_book"],
      steps: [
        "fa",
        {:use, "
  """

  defp items(line, column) do
    @source
    |> Cursor.context(line, column)
    |> Complete.items(@entries, Cursor.scan_aliases(@source, line))
  end

  test "in steps: steps, recipes and alias prefixes, with details" do
    items = items(6, 10)
    labels = Enum.map(items, & &1.label)

    assert "fake_book:hello" in labels
    assert "fake_book:main/base" in labels
    assert "fb:" in labels
    assert "fb:hello" in labels
    refute "fake_book:main/" in labels

    assert %{kind: :step, detail: "Writes hello.txt", range: {{6, 8}, {6, 10}}} =
             Enum.find(items, &(&1.label == "fake_book:hello"))

    assert %{kind: :alias, detail: "alias for fake_book"} = Enum.find(items, &(&1.label == "fb:"))
  end

  test "in {:use, \": recipes only" do
    labels = Enum.map(items(7, 15), & &1.label)
    assert labels == ["fake_book:main/base", "fb:main/base"]
  end

  test "nothing outside steps:" do
    assert items(3, 17) == []
  end
end
