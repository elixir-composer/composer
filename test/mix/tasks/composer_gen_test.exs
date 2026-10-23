defmodule Mix.Tasks.Composer.GenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp parses!(igniter, path) do
    source = content(igniter, path)
    assert {:ok, _} = Code.string_to_quoted(source), "#{path} does not parse"
    source
  end

  test "gen.cookbook writes the standard layout" do
    igniter = Igniter.compose_task(test_project(), "composer.gen.cookbook", [])

    cookbook = parses!(igniter, "lib/composer/test.ex")
    assert cookbook =~ "defmodule Composer.Test do"
    refute cookbook =~ "Code.ensure_loaded?"

    for path <- ["steps/.gitkeep", "recipes/app.exs", "manifest.exs"] do
      assert_creates(igniter, "lib/composer/test/" <> path)
    end

    # Templates live beside their steps; there is no cookbook-level templates/.
    refute Igniter.exists?(igniter, "lib/composer/test/templates/.gitkeep")

    {manifest, _} = Code.eval_string(content(igniter, "lib/composer/test/manifest.exs"))

    assert %{
             name: "test",
             package: :test,
             steps: [],
             recipes: [%{id: "app/default", shortdoc: "The default recipe of test"}]
           } = manifest

    {group, _} = Code.eval_string(content(igniter, "lib/composer/test/recipes/app.exs"))
    assert group == [default: [shortdoc: "The default recipe of test", steps: []]]
  end

  test "gen.cookbook --bundled guards the module" do
    igniter = Igniter.compose_task(test_project(), "composer.gen.cookbook", ["--bundled"])
    assert parses!(igniter, "lib/composer/test.ex") =~ "if Code.ensure_loaded?(Composer) do"
  end

  test "gen.step writes a step with every facet stubbed, and its test" do
    igniter =
      test_project()
      |> Igniter.compose_task("composer.gen.cookbook", ["--bundled"])
      |> Igniter.compose_task("composer.gen.step", ["ash/postgres"])

    step = parses!(igniter, "lib/composer/test/steps/ash/postgres.ex")
    assert step =~ "defmodule Composer.Test.Steps.Ash.Postgres do"
    assert step =~ "if Code.ensure_loaded?(Composer) do"

    for facet <- Composer.Facets.known() -- [:author, :license, :homepage] do
      assert step =~ "#{facet}: ", "#{facet} is not stubbed"
    end

    test = parses!(igniter, "test/composer/test/steps/ash/postgres_test.exs")
    assert test =~ "defmodule Composer.Test.Steps.Ash.PostgresTest do"
    assert test =~ "Igniter.compose_task(Composer.Test.Steps.Ash.Postgres)"
  end

  test "gen.step's stubbed facets are valid" do
    igniter = Igniter.compose_task(test_project(), "composer.gen.step", ["thing"])
    source = content(igniter, "lib/composer/test/steps/thing.ex")

    {:ok, {:defmodule, _, [_name, [do: {:__block__, _, [{:use, _, [_step, opts]} | _]}]]}} =
      Code.string_to_quoted(source)

    assert {:ok, _facets, []} = Composer.Facets.validate(opts)
    assert Enum.any?(igniter.warnings, &(&1 =~ "mix composer.gen.cookbook"))
  end

  test "gen.step rejects an invalid path" do
    assert_raise Mix.Error, ~r/Invalid step path/, fn ->
      Igniter.compose_task(test_project(), "composer.gen.step", ["Bad/Path"])
    end
  end

  test "gen.recipe creates a group in the cookbook" do
    igniter = Igniter.compose_task(test_project(), "composer.gen.recipe", ["phoenix/base"])
    source = parses!(igniter, "lib/composer/test/recipes/phoenix.exs")
    assert source =~ "mix composer.recipe.run test:phoenix/base"

    assert {[base: [shortdoc: "TODO: describe this recipe in one line", steps: []]], _} =
             Code.eval_string(source)
  end

  test "gen.recipe appends to an existing group, keeping it valid" do
    igniter =
      test_project(
        files: %{
          "lib/composer/test/recipes/ash.exs" => """
          # My Ash recipes.
          [
            # The base.
            base: [shortdoc: "Base", steps: ["core:setup/credo"]]
          ]
          """
        }
      )
      |> Igniter.compose_task("composer.gen.recipe", ["ash/auth"])

    source = parses!(igniter, "lib/composer/test/recipes/ash.exs")
    assert source =~ "# My Ash recipes."
    assert source =~ "# The base."

    {group, _} = Code.eval_string(source)
    assert Keyword.keys(group) == [:base, :auth]
    assert {[_, _], []} = Composer.Recipe.Group.check(group, "ash.exs", "test")
  end

  test "gen.recipe rejects a duplicate and an ungrouped name" do
    project =
      test_project(
        files: %{"lib/composer/test/recipes/ash.exs" => ~s([base: [shortdoc: "B", steps: []]])}
      )

    assert_raise Mix.Error, ~r/test:ash\/base already exists/, fn ->
      Igniter.compose_task(project, "composer.gen.recipe", ["ash/base"])
    end

    for bad <- ["base", "a/b/c", "Ash/base"] do
      assert_raise Mix.Error, ~r/Give it as group\/name/, fn ->
        Igniter.compose_task(test_project(), "composer.gen.recipe", [bad])
      end
    end
  end
end
