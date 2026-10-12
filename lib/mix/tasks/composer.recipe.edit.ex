defmodule Mix.Tasks.Composer.Recipe.Edit do
  @shortdoc "Opens a recipe's group file in your editor"

  @moduledoc """
  Opens the group file that holds a recipe in your editor, at the line
  where the recipe starts.

      $ mix composer.recipe.edit local:phx/app

  The editor command comes from `COMPOSER_EDITOR`, then `VISUAL`, then
  `EDITOR`; `__FILE__` and `__LINE__` in it are replaced with the file and
  line (see `Composer.Editor`):

      # Neovim in the current terminal
      export COMPOSER_EDITOR="nvim +__LINE__ __FILE__"

      # Neovim in a new Ghostty window
      export COMPOSER_EDITOR="ghostty -e 'nvim +__LINE__ __FILE__'"

  The recipe is found as `mix composer.recipe.run` finds it, but is not
  evaluated, so a recipe that fails to load can still be opened, as long
  as its group file parses. A recipe from a dependency's cookbook opens
  too, with a warning: edits under `deps/` are lost when the dependency
  is updated.

  ## Options

    * `-c`, `--config` - the local config directory (see `Composer.Local`)
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

    cookbooks = CLI.cookbooks!(opts[:config])
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
      warn_if_dep(path)
      open!(path, line)
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

  defp warn_if_dep(path) do
    deps = Path.expand(Mix.Project.deps_path())

    if String.starts_with?(Path.expand(path), deps <> "/") do
      Mix.shell().info([
        :yellow,
        "warning: #{path} belongs to a dependency; edits are lost when it is updated",
        :reset
      ])
    end
  end

  defp open!(path, line) do
    command =
      case Editor.command(path, line) do
        {:ok, command} ->
          command

        {:error, :no_editor} ->
          Mix.raise("""
          No editor set. Set one of #{Enum.join(Editor.vars(), ", ")}, e.g.

              export COMPOSER_EDITOR="nvim +__LINE__ __FILE__"
          """)
      end

    case Editor.run(command) do
      :ok -> :ok
      {:error, {:exit, status}} -> Mix.raise("Editor exited with status #{status}: #{command}")
    end
  end
end
