defmodule Mix.Tasks.Composer.ListTest do
  # Sets the :composer application env, read by every task.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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
          {"core:setup/credo", if: :credo},
          "setup/gitignore",
          "core:setup/gitignore"
        ]
      ]
    ]
    """)

    Application.put_env(:composer, :discovery, modules: [Composer.FakeBook])
    on_exit(fn -> Application.delete_env(:composer, :discovery) end)
    %{config: dir}
  end

  defp run(task, argv) do
    Mix.Task.reenable(task)
    capture_io(fn -> Mix.Task.run(task, argv) end)
  end

  defp json(task, argv), do: run(task, argv ++ ["--json"]) |> Jason.decode!()

  test "cookbook.list shows each cookbook with its counts", %{config: config} do
    output = run("composer.cookbook.list", ["-c", config])
    assert output =~ ~r/core\s+composer\s+30 steps\s+1 recipes/
    assert output =~ ~r/fake_book\s+fake_book\s+\d+ steps\s+3 recipes\s+A fixture cookbook/
    assert output =~ ~r/local\s+0 steps\s+1 recipes/

    assert %{"cookbooks" => [%{"name" => "core", "steps" => 30} | _]} =
             json("composer.cookbook.list", ["-c", config])
  end

  test "step.list filters by cookbook, framework, action and tag", %{config: config} do
    output = run("composer.step.list", ["-c", config, "--cookbook", "fake_book"])
    assert output =~ ~r/fake_book:ash\/postgres\s+add\s+Adds AshPostgres/
    refute output =~ "core:"

    assert run("composer.step.list", ["-c", config, "--framework", "ash"]) =~
             "fake_book:ash/postgres"

    assert run("composer.step.list", ["-c", config, "--tag", "greeting"]) =~ "fake_book:hello"

    removes = json("composer.step.list", ["-c", config, "--action", "remove"])["steps"]
    assert length(removes) == 5
    assert Enum.all?(removes, &(&1["action"] == "remove"))

    assert %{
             "ref" => "fake_book:ash/postgres",
             "frameworks" => ["ash", "ecto"],
             "requires" => [%{"step" => "fake_book:hello"}],
             "provides" => ["datalayer"]
           } =
             Enum.find(
               json("composer.step.list", ["-c", config])["steps"],
               &(&1["id"] == "ash/postgres")
             )
  end

  test "step.find ranks id matches before summary and tag matches", %{config: config} do
    ids = Enum.map(json("composer.step.find", ["-c", config, "postgres"])["steps"], & &1["ref"])
    assert hd(ids) == "fake_book:ash/postgres"

    assert Enum.map(json("composer.step.find", ["-c", config, "GREETING"])["steps"], & &1["ref"]) ==
             ["fake_book:hello"]

    assert run("composer.step.find", ["-c", config, "zzzz"]) =~ "No steps found."
  end

  test "step.show shows facets, requires and a dry run", %{config: config} do
    output = run("composer.step.show", ["-c", config, "fake_book:ash/postgres"])
    assert output =~ "fake_book:ash/postgres - Adds AshPostgres"
    assert output =~ ~r/requires:\s+fake_book:hello/
    assert output =~ ~r/files: .*postgres.txt/

    data = json("composer.step.show", ["-c", config, "core:setup/credo"])
    assert data["summary"] == "Adds Credo for static code analysis"
    assert %{"files" => ["mix.exs"], "deps" => ["credo"]} = data["dry_run"]

    assert run("composer.step.show", ["-c", config, "oban"]) =~ "hex:oban - the Hex package oban"

    assert run("composer.step.show", ["-c", config, "hex:my-lib@path:../my-lib"]) =~
             "hex:my_lib - the Hex package my_lib"
  end

  test "step.help and recipe.help are hidden aliases for the show tasks", %{config: config} do
    assert run("composer.step.help", ["-c", config, "oban"]) =~ "hex:oban - the Hex package oban"

    assert run("composer.recipe.help", ["-c", config, "phx/standard_app"]) =~
             "Recipe local:phx/standard_app"

    refute Mix.Task.shortdoc(Mix.Tasks.Composer.Step.Help)
    refute Mix.Task.shortdoc(Mix.Tasks.Composer.Recipe.Help)
  end

  test "recipe.list lists local recipes first, then cookbooks'", %{config: config} do
    output = run("composer.recipe.list", ["-c", config])
    assert output =~ ~r/\A\s+local:phx\/standard_app\s+My usual setup\n/
    assert output =~ ~r/fake_book:nested\/extra\s+Extra steps/

    assert [
             %{
               "ref" => "local:phx/standard_app",
               "cookbook" => "local",
               "group" => "phx",
               "name" => "standard_app",
               "shortdoc" => "My usual setup"
             }
             | _
           ] = json("composer.recipe.list", ["-c", config])["recipes"]
  end

  test "recipe.list takes cookbooks and groups", %{config: config} do
    refs =
      &Enum.map(json("composer.recipe.list", ["-c", config | &1])["recipes"], fn p ->
        p["ref"]
      end)

    assert refs.(["local"]) == ["local:phx/standard_app"]

    assert refs.(["fake_book"]) == [
             "fake_book:main/base",
             "fake_book:main/full",
             "fake_book:nested/extra"
           ]

    assert refs.(["fake_book", "local"]) == refs.(["fake_book"]) ++ refs.(["local"])
    assert refs.(["fake_book:main/"]) == ["fake_book:main/base", "fake_book:main/full"]
    assert refs.(["core"]) == ["core:debug/echo"]
  end

  test "recipe.list rejects commas, unknown cookbooks and groups", %{config: config} do
    assert_raise Mix.Error,
                 ~r/separate arguments.*mix composer.recipe.list local fake_book/s,
                 fn ->
                   run("composer.recipe.list", ["-c", config, "local,", "fake_book"])
                 end

    assert_raise Mix.Error, ~r/separate arguments.*list local fake_book/s, fn ->
      run("composer.recipe.list", ["-c", config, "local,fake_book"])
    end

    assert_raise Mix.Error, ~r/names the cookbook "nope", which is not installed/, fn ->
      run("composer.recipe.list", ["-c", config, "nope"])
    end

    assert_raise Mix.Error,
                 ~r/fake_book has no recipe group "ash".*fake_book:main\/, fake_book:nested\//s,
                 fn ->
                   run("composer.recipe.list", ["-c", config, "fake_book:ash/"])
                 end

    assert_raise Mix.Error, ~r/trailing slash/, fn ->
      run("composer.recipe.list", ["-c", config, "fake_book:main/base"])
    end
  end

  test "recipe.list warns about a group that does not load", %{config: config} do
    File.write!(Path.join(config, "recipes/old.exs"), ~s(["core:setup/credo"]\n))

    output = run("composer.recipe.list", ["-c", config, "local"])
    assert output =~ "local:phx/standard_app"
    assert output =~ ~r/warning: Recipe group .*old.exs must evaluate to a keyword list/

    assert [warning] = json("composer.recipe.list", ["-c", config, "local"])["warnings"]
    assert warning =~ "old.exs"
  end

  test "recipe.show shows docs, flags, resolved steps, duplicates and warnings", %{
    config: config
  } do
    output = run("composer.recipe.show", ["-c", config, "phx/standard_app"])

    assert output =~ "Recipe local:phx/standard_app"
    assert output =~ "My usual setup"
    assert output =~ "Builds on fake_book:main/full."
    assert output =~ ~r/Flags:\n\s+--credo\s+Add Credo/
    assert output =~ ~r/Flags from used recipes:\n\s+--extra\s+Add the extra steps/
    assert output =~ "1. fake_book:hello  [fake_book:main/base]"
    assert output =~ "core:setup/credo, if: :credo  [local:phx/standard_app]"
    assert output =~ "Duplicates dropped"
    assert output =~ "fake_book:sqlite (phase cleanup) runs after fake_book:hello (phase setup)"
    assert output =~ "all provide :datalayer"

    data = json("composer.recipe.show", ["-c", config, "local:phx/standard_app"])
    assert data["recipe"] == "local:phx/standard_app"
    assert data["shortdoc"] == "My usual setup"
    assert data["doc"] == "Builds on fake_book:main/full."
    assert data["group"] == "phx"
    assert data["name"] == "standard_app"

    assert data["flags"] == [
             %{"name" => "credo", "description" => "Add Credo"},
             %{"name" => "extra", "description" => "Add the extra steps"}
           ]

    assert Enum.any?(data["steps"], &(&1["ref"] == "fake_book:ash/postgres"))
    assert Enum.any?(data["duplicates"], &(&1["ref"] == "fake_book:ash/postgres"))
    assert data["warnings"] != []
  end

  test "recipe.show marks aliased steps inline; JSON keeps real names", %{config: config} do
    File.write!(Path.join(config, "recipes/lab.exs"), """
    [
      aliased: [
        shortdoc: "Aliased",
        aliases: [fb: "fake_book"],
        steps: ["fb:sqlite", "core:setup/gitignore"]
      ]
    ]
    """)

    output = run("composer.recipe.show", ["-c", config, "lab/aliased"])
    assert output =~ "1. fake_book:sqlite (as fb)  [local:lab/aliased]"
    assert output =~ "2. core:setup/gitignore  [local:lab/aliased]"

    data = json("composer.recipe.show", ["-c", config, "lab/aliased"])
    assert data["aliases"] == %{"fb" => "fake_book"}

    assert [%{"ref" => "fake_book:sqlite", "label" => "fake_book:sqlite", "alias" => "fb"}, _] =
             data["steps"]
  end

  test "errors are raised with their message", %{config: config} do
    assert_raise Mix.Error, ~r/no step matches "fake_book:nope"/, fn ->
      run("composer.step.show", ["-c", config, "fake_book:nope"])
    end

    assert_raise Mix.Error, ~r/no recipe matches "nope"/, fn ->
      run("composer.recipe.show", ["-c", config, "nope"])
    end
  end
end
