defmodule Composer.LSP.LookupTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.{Cursor, Lookup}
  alias Composer.Test.LSPFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {snapshot, path} = LSPFixtures.workspace(dir)
    %{snapshot: snapshot, path: path}
  end

  defp lookup(%{snapshot: snapshot, path: path}, line, column) do
    LSPFixtures.app_source() |> Cursor.at(path, line, column) |> Lookup.resolve(path, snapshot)
  end

  test "a qualified step", context do
    assert {:step, %{ref: "fake_book:hello"}} = lookup(context, 8, 8)
  end

  test "a step behind a cookbook alias", context do
    assert {:step, %{ref: "fake_book:ash:postgres"}} = lookup(context, 9, 8)
  end

  test "hex:, and a bare word, which is not an address in source", context do
    assert lookup(context, 10, 8) == {:hex, "oban", :explicit}
    assert {:error, {:bare_word, "oban", nil, ["hex:oban"], []}} = lookup(context, 11, 8)
  end

  test "includes, relative and qualified", context do
    assert {:recipe, %{ref: "mine/app/base", doc: "The base."}} = lookup(context, 12, 9)
    assert {:recipe, %{ref: "fake_book/main/full"}} = lookup(context, 13, 15)
  end

  test "a recipe's name key", context do
    assert {:recipe, %{ref: "mine/app/app"}} = lookup(context, 4, 3)
  end

  test "an alias name", context do
    assert lookup(context, 1, 13) == {:alias, "fb", "fake_book"}
  end

  test "a reference that does not resolve", context do
    assert {:error, {:unknown_cookbook, "nope", "nope:x", _, _}} = lookup(context, 14, 8)
  end

  test "the buffer's context is its cookbook and chapter path", %{snapshot: snapshot, path: path} do
    assert Lookup.context(snapshot.cookbooks, path) == %{
             cookbook: "mine",
             chapter: "app",
             cli?: false
           }

    assert Lookup.context(snapshot.cookbooks, "mix.exs").cookbook == nil
  end

  test "alias expansion" do
    assert Lookup.expand("lab:x:y", %{"lab" => "cc_lab"}) == "cc_lab:x:y"
    assert Lookup.expand("cb_std:x", %{"lab" => "cc_lab"}) == "cb_std:x"
  end
end
