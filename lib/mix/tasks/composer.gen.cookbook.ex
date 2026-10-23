defmodule Mix.Tasks.Composer.Gen.Cookbook do
  @shortdoc "Scaffolds this project's composer cookbook"

  @moduledoc """
  Scaffolds the current project's cookbook:

      lib/composer/<app>.ex                 # the cookbook module
      lib/composer/<app>/steps/.gitkeep
      lib/composer/<app>/recipes/app.exs    # the recipe app/default
      lib/composer/<app>/manifest.exs

  ## Usage

      mix composer.gen.cookbook
      mix composer.gen.cookbook --bundled

  ## Bundling with a framework

  A framework that ships a cookbook alongside its own code, with composer as
  an *optional* dependency, passes `--bundled`. The cookbook module is then
  wrapped in `if Code.ensure_loaded?(Composer) do ... end`, so it compiles to
  nothing - and costs nothing - when composer is absent. Steps generated
  later with `mix composer.gen.step` get the same guard. Use it too when
  composer is a dev-only dependency of an app.

  ## Options

    * `--bundled` - guard the cookbook so it compiles without composer
  """

  use Igniter.Mix.Task

  alias Composer.{Helpers, Manifest}

  # Igniter writes no empty files, so .gitkeep says what it is for.
  @gitkeep "Keeps this directory in git until it has files of its own.\n"

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      schema: [bundled: :boolean],
      example: "mix composer.gen.cookbook --bundled"
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    name = cookbook_name(app)
    root = "lib/composer/#{name}"
    bundled? = Keyword.get(igniter.args.options, :bundled, false)

    # Every file is left alone if it exists, so re-running is harmless and
    # mix composer.init can write its own default recipe first.
    igniter
    |> Helpers.create_unless_exists(
      "lib/composer/#{name}.ex",
      cookbook_source(app, name, bundled?)
    )
    |> Helpers.create_unless_exists("#{root}/steps/.gitkeep", @gitkeep)
    |> Helpers.create_unless_exists("#{root}/recipes/app.exs", default_recipe(name))
    |> write_manifest(app, name, "#{root}/recipes/app.exs", "#{root}/manifest.exs")
    |> Igniter.add_notice("""
    Your cookbook is lib/composer/#{name}/. Add steps and recipes with:

        mix composer.gen.step my_step
        mix composer.gen.recipe my_group/my_recipe

    and refresh the manifest with `mix composer.cookbook.manifest`.
    """)
  end

  # The manifest lists the group's recipes with their shortdocs, read from
  # the file actually being written (mix composer.init writes its own first),
  # so the new cookbook passes mix composer.cookbook.lint. The file is our
  # own generated source (or a recipe the user chose to copy).
  defp write_manifest(igniter, app, name, recipe, path) do
    igniter = Igniter.include_existing_file(igniter, recipe)
    content = igniter.rewrite |> Rewrite.source!(recipe) |> Rewrite.Source.get(:content)

    recipes =
      try do
        {term, _binding} = Code.eval_string(content)
        {loaded, _errors} = Composer.Recipe.Group.check(term, recipe, name)
        loaded |> Enum.map(&%{id: &1.id, shortdoc: &1.shortdoc}) |> Enum.sort_by(& &1.id)
      rescue
        _ -> []
      end

    manifest = %{
      name: name,
      package: app,
      steps: [],
      recipes: recipes
    }

    Helpers.create_unless_exists(igniter, path, Manifest.render(manifest))
  end

  @doc false
  # composer's own cookbook is the one exception to "named after the app".
  def cookbook_name(:composer), do: "core"
  def cookbook_name(app), do: Atom.to_string(app)

  @doc false
  # Wraps generated source in the optional-dependency guard.
  def guard(source, false), do: source

  def guard(source, true) do
    body = source |> String.split("\n") |> Enum.map_join("\n", &indent/1)

    """
    # Composer is an optional (or dev-only) dependency, so this module is only
    # defined when Composer is available; without it, this file compiles to
    # nothing. Do not remove the surrounding `if`.
    if Code.ensure_loaded?(Composer) do
    #{String.trim_trailing(body)}
    end
    """
  end

  defp indent(""), do: ""
  defp indent(line), do: "  " <> line

  defp cookbook_source(app, name, bundled?) do
    module = Composer.Cookbook.module_for(name)

    """
    defmodule #{inspect(module)} do
      @moduledoc \"\"\"
      The composer cookbook of #{app}: steps (with their templates) and
      recipes under lib/composer/#{name}/.

      List them with `mix composer.step.list --cookbook #{name}` and
      `mix composer.recipe.list`.
      \"\"\"

      use Composer.Cookbook, summary: "Composer steps and recipes for #{app}"
    end
    """
    |> guard(bundled?)
  end

  defp default_recipe(name) do
    """
    # The app recipe group of #{name}. Run its default recipe with:
    #
    #     mix composer.recipe.run #{name}:app/default
    #
    # Each recipe has a shortdoc:, an optional doc: and flags:, and steps:,
    # one entry per line: "cookbook:path" steps, {"ref", if: :flag},
    # {:use, "recipe"}, {:task, "x.y", argv} and {:queue, "x.y", argv}.
    # Browse steps with `mix composer.step.list`.
    [
      default: [
        shortdoc: "The default recipe of #{name}",
        steps: []
      ]
    ]
    """
  end
end
