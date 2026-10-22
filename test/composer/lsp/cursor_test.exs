defmodule Composer.LSP.CursorTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.Cursor

  @fixture "test/support/fixtures/locator/positions.exs"

  setup do
    text = File.read!(@fixture)
    # Without the closing bracket of auth's steps:, the file does not parse.
    broken = text |> String.split("\n") |> List.replace_at(20, "") |> Enum.join("\n")
    assert {:error, _} = Code.string_to_quoted(broken)
    %{text: text, broken: broken}
  end

  for {name, key} <- [locator: :text, "line scan": :broken] do
    describe "#{name}" do
      test "a ref, with the recipe's aliases", context do
        text = context[unquote(key)]

        assert %{kind: :ref, value: "lab:auth/passkeys", range: {{12, 7}, {12, 26}}} =
                 cursor = Cursor.at(text, @fixture, 12, 10)

        assert cursor.recipe == "auth"
        assert cursor.aliases == %{"lab" => "cc_lab"}
      end

      test "a {:use, ...} target", context do
        assert %{kind: :use, value: "base", range: {{18, 14}, {18, 20}}} =
                 Cursor.at(context[unquote(key)], @fixture, 18, 15)
      end

      test "an escaped quote", context do
        assert %{kind: :ref, value: ~s(esc"aped)} =
                 Cursor.at(context[unquote(key)], @fixture, 20, 12)
      end

      test "nothing outside a literal", context do
        assert Cursor.at(context[unquote(key)], @fixture, 12, 3) == nil
      end
    end
  end

  test "an alias name, with the locator", %{text: text} do
    assert %{kind: :alias, value: :lab, recipe: "auth"} = Cursor.at(text, @fixture, 2, 12)
  end

  test "literals: escapes, comments and an unclosed string" do
    assert [%{value: "a", start: 1, end: 4}, %{value: ~s(b"c), start: 6, end: 12}] =
             Cursor.literals(~S("a", "b\"c" # "not"))

    assert [%{value: "core:se", start: 3, end: nil}] = Cursor.literals(~s(  "core:se))
    assert Cursor.literal_at(~s(  "ab" ), 5) == %{value: "ab", start: 3, end: 7}
    assert Cursor.literal_at(~s(  "ab" ), 7) == nil
  end

  describe "context/3" do
    @source """
    [
      app: [
        shortdoc: "Some ",
        aliases: [fb: "fake_book"],
        steps: [
          "co",
          {"core:setup/credo",
           if: :credo},
          "x", {:use, "fake
    """

    test "a literal in steps:, the literal's contents replaced" do
      assert Cursor.context(@source, 6, 10) == {:steps, "co", {{6, 8}, {6, 10}}}
    end

    test "after an entry spanning lines" do
      assert {:steps, "", _} = Cursor.context(@source, 9, 8)
    end

    test "{:use, \" in an unclosed literal" do
      assert Cursor.context(@source, 9, 24) == {:use, "fake", {{9, 20}, {9, 24}}}
    end

    test "not in shortdoc:, aliases: or outside a literal" do
      assert Cursor.context(@source, 3, 17) == nil
      assert Cursor.context(@source, 4, 21) == nil
      assert Cursor.context(@source, 6, 5) == nil
    end

    test "on the steps: line itself" do
      assert {:steps, "co", _} = Cursor.context(~s(  a: [steps: ["co"]]), 1, 18)
    end
  end

  test "aliases are scanned from lists and bindings, the nearest first" do
    text = """
    shared = [lab: "cc_lab"]
    [
      a: [aliases: [lab: "other", x: "y"], steps: []],
      b: [aliases: shared, steps: []]
    ]
    """

    assert Cursor.scan_aliases(text, 3) == %{"lab" => "other", "x" => "y"}
    assert Cursor.scan_aliases(text, 2) == %{"lab" => "cc_lab", "x" => "y"}
  end
end
