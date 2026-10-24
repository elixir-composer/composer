defmodule Mix.Tasks.Composer.ListTest do
  # Sets the :composer application env, read by every task.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "recipes"))

    File.write!(Path.join(dir, "recipes/phx.exs"), """
    [
      standard_app: [
        shortdoc: "My usual setup",
        doc: "Builds on fake_book:main/full.",
        flags: [credo: "Add Credo"],
        steps: [
          {:use, "fake_book:main/full"},
          "fake_book:ash/postgres",
          "fake_book:sqlite",
          {"cb_std:setup/credo", if: :credo},
          "setup/gitignore",
          "cb_std:setup/gitignore"
        ]
      ]
    ]
    """)

    Application.put_env(:composer, :discovery,
      modules: [Composer.FakeBook],
      cookbooks: [code_cookbook(dir)]
    )

    on_exit(fn -> Application.delete_env(:composer, :discovery) end)
    :ok
  end

  defp run(task, argv) do
    Mix.Task.reenable(task)
    capture_io(fn -> Mix.Task.run(task, argv) end)
  end

  defp json(task, argv), do: run(task, argv ++ ["--json"]) |> Jason.decode!()

  test "cookbook.list shows each cookbook with its counts" do
    output = run("composer.cookbook.list", [])
    assert output =~ ~r/cb_std\s+composer\s+30 steps\s+1 recipes/
    assert output =~ ~r/fake_book\s+fake_book\s+\d+ steps\s+3 recipes\s+A fixture cookbook/
    assert output =~ ~r/mine\s+composer\s+0 steps\s+1 recipes/

    assert %{"cookbooks" => [%{"name" => "cb_std", "steps" => 30} | _]} =
             json("composer.cookbook.list", [])
  end

  test "step.list filters by cookbook, framework, action and tag" do
    output = run("composer.step.list", ["--cookbook", "fake_book"])
    assert output =~ ~r/fake_book:ash\/postgres\s+add\s+Adds AshPostgres/
    refute output =~ "cb_std:"

    assert run("composer.step.list", ["--framework", "ash"]) =~
             "fake_book:ash/postgres"

    assert run("composer.step.list", ["--tag", "greeting"]) =~ "fake_book:hello"

    removes = json("composer.step.list", ["--action", "remove"])["steps"]
    assert length(removes) == 5
    assert Enum.all?(removes, &(&1["action"] == "remove"))

    assert %{
             "ref" => "fake_book:ash/postgres",
             "frameworks" => ["ash", "ecto"],
             "requires" => [%{"step" => "fake_book:hello"}],
             "provides" => ["datalayer"]
           } =
             Enum.find(
               json("composer.step.list", [])["steps"],
               &(&1["id"] == "ash/postgres")
             )
  end

  test "step.find ranks id matches before summary and tag matches" do
    ids = Enum.map(json("composer.step.find", ["postgres"])["steps"], & &1["ref"])
    assert hd(ids) == "fake_book:ash/postgres"

    assert Enum.map(json("composer.step.find", ["GREETING"])["steps"], & &1["ref"]) ==
             ["fake_book:hello"]

    assert run("composer.step.find", ["zzzz"]) =~ "No steps found."
  end

  test "step.show shows facets, requires and a dry run" do
    output = run("composer.step.show", ["fake_book:ash/postgres"])
    assert output =~ "fake_book:ash/postgres - Adds AshPostgres"
    assert output =~ ~r/requires:\s+fake_book:hello/
    assert output =~ ~r/files: .*postgres.txt/

    data = json("composer.step.show", ["cb_std:setup/credo"])
    assert data["summary"] == "Adds Credo for static code analysis"
    assert %{"files" => ["mix.exs"], "deps" => ["credo"]} = data["dry_run"]

    assert run("composer.step.show", ["oban"]) =~ "hex:oban - the Hex package oban"

    assert run("composer.step.show", ["hex:my-lib@path:../my-lib"]) =~
             "hex:my_lib - the Hex package my_lib"
  end

  test "step.help and recipe.help are hidden aliases for the show tasks" do
    assert run("composer.step.help", ["oban"]) =~ "hex:oban - the Hex package oban"

    assert run("composer.recipe.help", ["phx/standard_app"]) =~
             "Recipe mine:phx/standard_app"

    refute Mix.Task.shortdoc(Mix.Tasks.Composer.Step.Help)
    refute Mix.Task.shortdoc(Mix.Tasks.Composer.Recipe.Help)
  end

  test "recipe.list lists every cookbook's recipes, in discovery order" do
    output = run("composer.recipe.list", [])

    assert output =~
             ~r/fake_book:nested\/extra\s+Extra steps\n\s+mine:phx\/standard_app\s+My usual setup/

    assert [
             %{
               "ref" => "mine:phx/standard_app",
               "cookbook" => "mine",
               "chapter" => "phx",
               "name" => "standard_app",
               "shortdoc" => "My usual setup"
             }
           ] =
             Enum.filter(json("composer.recipe.list", [])["recipes"], &(&1["cookbook"] == "mine"))
  end

  test "recipe.list takes cookbooks and chapters" do
    refs =
      &Enum.map(json("composer.recipe.list", &1)["recipes"], fn p ->
        p["ref"]
      end)

    assert refs.(["mine"]) == ["mine:phx/standard_app"]

    assert refs.(["fake_book"]) == [
             "fake_book:main/base",
             "fake_book:main/full",
             "fake_book:nested/extra"
           ]

    assert refs.(["fake_book", "mine"]) == refs.(["fake_book"]) ++ refs.(["mine"])
    assert refs.(["fake_book:main/"]) == ["fake_book:main/base", "fake_book:main/full"]
    assert refs.(["cb_std"]) == ["cb_std:debug/echo"]
  end

  test "recipe.list --only-leaves hides recipes included within their chapter", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "recipes/site.exs"), """
    [
      ui: [shortdoc: "UI", steps: ["cb_std:setup/gitignore"]],
      parts: [shortdoc: "Parts", steps: [{:use, "mine:site/ui"}]],
      app: [shortdoc: "App", steps: [{:use, "parts"}, {:use, "phx/standard_app"}]]
    ]
    """)

    refs = &Enum.map(json("composer.recipe.list", &1)["recipes"], fn p -> p["ref"] end)

    # Unqualified and self-qualified includes both count; phx/standard_app
    # and fake_book:nested/extra are only used from other chapters.
    assert refs.(["mine:site/", "--only-leaves"]) == ["mine:site/app"]
    assert refs.(["mine", "--only-leaves"]) == ["mine:phx/standard_app", "mine:site/app"]

    assert refs.(["fake_book", "--only-leaves"]) == [
             "fake_book:main/full",
             "fake_book:nested/extra"
           ]

    leaves =
      Map.new(json("composer.recipe.list", ["mine:site/"])["recipes"], &{&1["name"], &1["leaf"]})

    assert leaves == %{"ui" => false, "parts" => false, "app" => true}

    output = run("composer.recipe.list", ["mine:site/", "--only-leaves"])
    assert output =~ "mine:site/app"
    refute output =~ "mine:site/ui"
  end

  test "recipe.list rejects commas, unknown cookbooks and chapters" do
    assert_raise Mix.Error,
                 ~r/separate arguments.*mix composer.recipe.list mine fake_book/s,
                 fn ->
                   run("composer.recipe.list", ["mine,", "fake_book"])
                 end

    assert_raise Mix.Error, ~r/separate arguments.*list mine fake_book/s, fn ->
      run("composer.recipe.list", ["mine,fake_book"])
    end

    assert_raise Mix.Error, ~r/names the cookbook "nope", which is not installed/, fn ->
      run("composer.recipe.list", ["nope"])
    end

    assert_raise Mix.Error,
                 ~r/fake_book has no chapter "ash".*fake_book:main\/, fake_book:nested\//s,
                 fn ->
                   run("composer.recipe.list", ["fake_book:ash/"])
                 end

    assert_raise Mix.Error, ~r/trailing slash/, fn ->
      run("composer.recipe.list", ["fake_book:main/base"])
    end
  end

  test "recipe.list warns about a chapter that does not load", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "recipes/old.exs"), ~s(["cb_std:setup/credo"]\n))

    output = run("composer.recipe.list", ["mine"])
    assert output =~ "mine:phx/standard_app"
    assert output =~ ~r/warning: Chapter .*old.exs must evaluate to a keyword list/

    assert [warning] = json("composer.recipe.list", ["mine"])["warnings"]
    assert warning =~ "old.exs"
  end

  test "recipe.show shows docs, flags, resolved steps, duplicates and warnings" do
    output = run("composer.recipe.show", ["phx/standard_app"])

    assert output =~ "Recipe mine:phx/standard_app"
    assert output =~ "My usual setup"
    assert output =~ "Builds on fake_book:main/full."
    assert output =~ ~r/Flags:\n\s+--credo\s+Add Credo/
    assert output =~ ~r/Flags from used recipes:\n\s+--extra\s+Add the extra steps/
    assert output =~ "1. fake_book:hello  [fake_book:main/base]"
    assert output =~ "cb_std:setup/credo, if: :credo  [mine:phx/standard_app]"
    assert output =~ "Duplicates dropped"
    assert output =~ "fake_book:sqlite (phase cleanup) runs after fake_book:hello (phase setup)"
    assert output =~ "all provide :datalayer"

    data = json("composer.recipe.show", ["mine:phx/standard_app"])
    assert data["recipe"] == "mine:phx/standard_app"
    assert data["shortdoc"] == "My usual setup"
    assert data["doc"] == "Builds on fake_book:main/full."
    assert data["chapter"] == "phx"
    assert data["name"] == "standard_app"

    assert data["flags"] == [
             %{"name" => "credo", "description" => "Add Credo"},
             %{"name" => "extra", "description" => "Add the extra steps"}
           ]

    assert Enum.any?(data["steps"], &(&1["ref"] == "fake_book:ash/postgres"))
    assert Enum.any?(data["duplicates"], &(&1["ref"] == "fake_book:ash/postgres"))
    assert data["warnings"] != []
  end

  test "recipe.show marks aliased steps inline; JSON keeps real names", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "recipes/lab.exs"), """
    [
      aliased: [
        shortdoc: "Aliased",
        aliases: [fb: "fake_book"],
        steps: ["fb:sqlite", "cb_std:setup/gitignore"]
      ]
    ]
    """)

    output = run("composer.recipe.show", ["lab/aliased"])
    assert output =~ "1. fake_book:sqlite (as fb)  [mine:lab/aliased]"
    assert output =~ "2. cb_std:setup/gitignore  [mine:lab/aliased]"

    data = json("composer.recipe.show", ["lab/aliased"])
    assert data["aliases"] == %{"fb" => "fake_book"}

    assert [%{"ref" => "fake_book:sqlite", "label" => "fake_book:sqlite", "alias" => "fb"}, _] =
             data["steps"]
  end

  test "errors are raised with their message" do
    assert_raise Mix.Error, ~r/no step matches "fake_book:nope"/, fn ->
      run("composer.step.show", ["fake_book:nope"])
    end

    assert_raise Mix.Error, ~r/no recipe matches "nope"/, fn ->
      run("composer.recipe.show", ["nope"])
    end
  end
end
