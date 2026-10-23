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
    assert {:step, %{ref: "fake_book:ash/postgres"}} = lookup(context, 9, 8)
  end

  test "hex: and a name that falls through to Hex", context do
    assert lookup(context, 10, 8) == {:hex, "oban", :explicit}
    assert lookup(context, 11, 8) == {:hex, "oban", :fallthrough}
  end

  test "{:use, ...} targets, in the same group and qualified", context do
    assert {:recipe, %{ref: "mine:app/base", doc: "The base."}} = lookup(context, 12, 15)
    assert {:recipe, %{ref: "fake_book:main/full"}} = lookup(context, 13, 15)
  end

  test "a recipe's name key", context do
    assert {:recipe, %{ref: "mine:app/app"}} = lookup(context, 4, 3)
  end

  test "an alias name", context do
    assert lookup(context, 1, 13) == {:alias, "fb", "fake_book"}
  end

  test "a reference that does not resolve", context do
    assert {:error, {:unknown_cookbook, "nope", "nope:x", _, _}} = lookup(context, 14, 8)
  end

  test "alias expansion" do
    assert Lookup.expand("lab:x/y", %{"lab" => "cc_lab"}) == "cc_lab:x/y"
    assert Lookup.expand("core:x", %{"lab" => "cc_lab"}) == "core:x"
  end
end
