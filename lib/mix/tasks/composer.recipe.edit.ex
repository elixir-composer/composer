defmodule Mix.Tasks.Composer.Recipe.Edit do
  @shortdoc "Opens a recipe's chapter file in your editor"

  @moduledoc """
  Opens the chapter file that holds a recipe in your editor, at the line
  where the recipe starts.

      $ mix composer.recipe.edit my_app:phx/app

  The editor command comes from `COMPOSER_EDITOR`, then `VISUAL`, then
  `EDITOR`; `__FILE__` and `__LINE__` in it are replaced with the file and
  line (see `Composer.Editor`):

      # Neovim in the current terminal
      export COMPOSER_EDITOR="nvim +__LINE__ __FILE__"

      # Neovim in a new Ghostty window
      export COMPOSER_EDITOR="ghostty -e nvim -c __LINE__ __FILE__"

  The recipe is found as `mix composer.recipe.run` finds it, but is not
  evaluated, so a recipe that fails to load can still be opened, as long
  as its chapter file parses. A recipe from a dependency's cookbook opens
  too, with a warning: edits under `deps/` are lost when the dependency
  is updated.

  ## Options

    * `--print` - print `path:line` instead of opening an editor
  """

  use Mix.Task

  alias Composer.{CLI, Cookbook, Editor, Error, Ref, Resolver}
  alias Composer.Recipe.Locator

  @impl Mix.Task
  def run(argv) do
    {opts, args} = CLI.parse!(argv, print: :boolean)

    ref =
      case args do
        [ref] -> ref
        _ -> Mix.raise("Usage: mix composer.recipe.edit RECIPE")
      end

    cookbooks = CLI.cookbooks!()
    id = CLI.ok!(Resolver.find_recipe(cookbooks, ref, CLI.context(cookbooks)))
    %Ref{cookbook: name, path: recipe} = Ref.parse!(id)
    cookbook = Enum.find(cookbooks, &(&1.name == name))

    path =
      Cookbook.recipe_path(cookbook, recipe) ||
        Mix.raise(Error.message({:missing_recipe, ref, nil, []}))

    line = line(path, Path.basename(recipe))

    if opts[:print] do
      Mix.shell().info("#{path}:#{line}")
    else
      Editor.warn_if_dep(path)
      Editor.open!(path, line)
    end
  end

  # The line of the recipe's name key; 1 when the file cannot be indexed.
  defp line(path, name) do
    with {:ok, index} <- Locator.index_file(path),
         %{key: {{line, _column}, _end}} <- Locator.recipe(index, name) do
      line
    else
      _ -> 1
    end
  end
end
