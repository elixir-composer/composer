defmodule Composer.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Composer.Discovery

  defp names({:ok, cookbooks}), do: Enum.map(cookbooks, & &1.name)

  test "core is always found; cookbooks are found by the Composer.<App> convention" do
    assert names(Discovery.cookbooks(apps: [])) == ["core"]

    # :fake_book is not a real dependency, so the convention lookup of an app
    # named :fake_book is what finds Composer.FakeBook.
    assert names(Discovery.cookbooks(apps: [:fake_book, :jason])) ==
             ["core", "fake_book"]
  end

  test "extra cookbooks come after the discovered ones" do
    mine = Composer.Test.Cookbooks.code_cookbook(System.tmp_dir!())

    assert ["core", "fake_book", "mine"] =
             names(Discovery.cookbooks(apps: [:fake_book], cookbooks: [mine]))
  end

  test "except: and only: limit package cookbooks, but never core" do
    opts = [apps: [:fake_book, :other_book]]

    assert names(Discovery.cookbooks(opts ++ [filter: [except: [:fake_book]]])) ==
             ["core", "other_book"]

    assert names(Discovery.cookbooks(opts ++ [filter: [only: ["other_book"]]])) ==
             ["core", "other_book"]
  end

  defmodule Impostor do
    @moduledoc false
    # Reports the name of another cookbook.
    def __composer_cookbook__ do
      %{
        name: "fake_book",
        app: :impostor,
        summary: nil,
        homepage: nil,
        source_dir: nil,
        recipes: []
      }
    end
  end

  test "two cookbooks with the same name are an error" do
    assert {:error, {:duplicate_cookbook, "fake_book", [Composer.FakeBook, Impostor]}} =
             Discovery.cookbooks(apps: [:fake_book], modules: [Impostor])

    assert Composer.Error.message(
             {:duplicate_cookbook, "fake_book", [Composer.FakeBook, Impostor]}
           ) =~
             "More than one cookbook is named \"fake_book\""
  end

  test "own/1 is the current project's cookbook (core, inside composer)" do
    {:ok, cookbooks} = Discovery.cookbooks(apps: [])
    assert %{name: "core"} = Discovery.own(cookbooks)
  end
end
