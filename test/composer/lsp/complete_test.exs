defmodule Composer.LSP.CompleteTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.{Complete, Cursor}

  @entries [
    {"cookbook", "fake_book", "A fixture cookbook"},
    {"step", "fake_book:hello", "Writes hello.txt"},
    {"group", "fake_book:ash:", "1 step"},
    {"step", "fake_book:ash:postgres", "Adds AshPostgres"},
    {"recipe", "fake_book/main/base", "The base recipe"},
    {"chapter", "fake_book/main/", "2 recipes"},
    {"cookbook", "mine", "Mine"},
    {"dir", "mine/ash/", "1 chapter, 1 directory"},
    {"chapter", "mine/ash/", "1 recipe"},
    {"recipe", "mine/ash/core", "Core"},
    {"chapter", "mine/ash/ui/", "2 recipes"},
    {"recipe", "mine/ash/ui/buttons", "Buttons"},
    {"recipe", "mine/ash/ui/forms", "Forms"},
    {"step", "mine:tools:thing", "A thing"}
  ]

  @buffer %{cookbook: "mine", chapter: "ash/ui"}

  defp labels(prefix, opts \\ []) do
    kind = Keyword.get(opts, :kind, :steps)
    aliases = Keyword.get(opts, :aliases, %{"fb" => "fake_book"})
    buffer = Keyword.get(opts, :buffer, @buffer)

    {kind, prefix, {{1, 1}, {1, 1}}}
    |> Complete.items(@entries, aliases, buffer)
    |> Enum.map(& &1.label)
  end

  test "empty: where an address can start" do
    assert labels("") ==
             ~w(./ ../ / : fake_book/ fake_book: mine/ mine: fb/ fb: hex:)
  end

  test "a name: cookbooks and aliases with that prefix" do
    assert labels("f") == ~w(fake_book/ fake_book: fb/ fb:)
  end

  test "qualified: the next segment, recipes and steps apart" do
    assert labels("fake_book/") == ["fake_book/main/"]
    assert labels("fake_book/main/") == ["fake_book/main/base"]
    assert labels("fake_book:") == ["fake_book:hello", "fake_book:ash:"]
    assert labels("fake_book:ash:") == ["fake_book:ash:postgres"]
  end

  test "an alias completes as written" do
    assert labels("fb:a") == ["fb:ash:"]
    assert labels("fb/main/") == ["fb/main/base"]
  end

  test "root: the buffer's cookbook" do
    assert labels("/") == ["/ash/"]
    assert labels("/ash/") == ["/ash/core", "/ash/ui/"]
    assert labels(":") == [":tools:"]
    assert labels("/", buffer: %{cookbook: nil, chapter: nil}) == []
  end

  test "relative: from the buffer's chapter" do
    assert labels("./") == ["./buttons", "./forms"]
    assert labels("./b") == ["./buttons"]
    assert labels("../") == ["../core", "../ui/"]
    assert labels("../../") == ["../../ash/"]
    assert labels("../../../") == []
    assert labels(".") == ["./", "../"]
  end

  test "details and kinds" do
    items = Complete.items({:steps, "fake_book:", {{6, 8}, {6, 18}}}, @entries, %{}, @buffer)

    assert %{kind: :step, detail: "Writes hello.txt", range: {{6, 8}, {6, 18}}} =
             Enum.find(items, &(&1.label == "fake_book:hello"))

    assert %{kind: :folder, detail: "1 step"} = Enum.find(items, &(&1.label == "fake_book:ash:"))

    assert %{kind: :alias, detail: "alias for fake_book"} =
             Enum.find(
               Complete.items(
                 {:steps, "", {{1, 1}, {1, 1}}},
                 @entries,
                 %{"fb" => "fake_book"},
                 @buffer
               ),
               &(&1.label == "fb:")
             )
  end

  test "in requires: steps only" do
    assert labels("", kind: :requires) == ~w(: fake_book: mine: fb: hex:)
    assert labels("fake_book/", kind: :requires) == []
    assert labels("./", kind: :requires) == []
  end

  test "from a buffer that does not parse, by line scan" do
    source = """
    [
      app: [
        shortdoc: "App",
        aliases: [fb: "fake_book"],
        steps: [
          "fake_book:h",
          "./
    """

    items = fn line, column ->
      source
      |> Cursor.context(line, column)
      |> Complete.items(@entries, Cursor.scan_aliases(source, line), @buffer)
      |> Enum.map(& &1.label)
    end

    assert items.(6, 19) == ["fake_book:hello"]
    assert items.(7, 10) == ["./buttons", "./forms"]
    assert items.(3, 17) == []
  end
end
