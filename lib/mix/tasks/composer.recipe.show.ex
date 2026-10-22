defmodule Mix.Tasks.Composer.Recipe.Show do
  @shortdoc "Shows a recipe's docs, flags and resolved steps"

  @moduledoc """
  Shows a recipe's metadata - shortdoc, doc and flags - and its fully
  expanded, numbered step list, with the recipe each step came from and
  the include flags that gate it.

      $ mix composer.recipe.show local:phx/app
      Recipe local:phx/app (/home/you/.config/composer/recipes/phx.exs)

      Standard Phoenix app

      Builds on phx/clean and phx/defaults.

      Flags:
        --gigalixir  Add Gigalixir deployment

      Steps:
         1. core:phx/remove_theme_toggle  [local:phx/clean]
         2. core:setup/credo  [local:dev/env]
         3. core:cluster/gigalixir  [local:deploy/gigalixir] if :gigalixir
         4. cc_lab:auth/passkeys (as lab)  [local:phx/app]
         5. core:setup/sort_deps  [local:phx/finish]

  Flags declared by recipes that this one `:use`s are listed after its
  own; `mix composer.recipe.run` accepts all of them.

  A step written with a cookbook alias (see `Composer.Recipe`) shows the
  real cookbook name followed by the alias it was written with, `(as lab)`.
  In `--json`, `"aliases"` holds the recipe's own aliases and each step's
  `"alias"` the one it was written with; `"ref"` and `"label"` always use
  the real name.

  Every gated include is followed, so the list shows everything the recipe
  can run. Steps dropped as duplicates are listed after it, then warnings:
  a step whose `phase` comes before that of a step listed ahead of it, two
  steps that `provide` the same capability or conflict, and a step whose
  required step is not listed earlier.

  ## Options

    * `-c`, `--config` - the local config directory (see `Composer.Local`)
    * `--json` - print JSON instead of text
  """

  use Mix.Task

  alias Composer.{CLI, Error, Resolver}

  @impl Mix.Task
  def run(argv) do
    {opts, args} = CLI.parse!(argv)

    ref =
      case args do
        [ref] -> ref
        _ -> Mix.raise("Usage: mix composer.recipe.show RECIPE")
      end

    cookbooks = CLI.cookbooks!(opts[:config])
    result = CLI.resolve_recipe!(cookbooks, ref, :all)
    [recipe | _] = result.recipes
    declared = Resolver.declared_flags(result)

    {own, used} =
      Enum.split_with(declared, fn {flag, _} -> Keyword.has_key?(recipe.flags, flag) end)

    warnings = Resolver.warnings(result.steps)

    if opts[:json] do
      CLI.json(%{
        "recipe" => result.root,
        "group" => recipe.group,
        "name" => recipe.name,
        "path" => recipe.path,
        "shortdoc" => recipe.shortdoc,
        "doc" => recipe.doc,
        "flags" =>
          Enum.map(declared, fn {flag, text} ->
            %{"name" => Atom.to_string(flag), "description" => text}
          end),
        "aliases" =>
          Map.new(recipe.aliases, fn {name, target} -> {Atom.to_string(name), target} end),
        "steps" => Enum.map(result.steps, &CLI.entry_data/1),
        "duplicates" => Enum.map(result.duplicates, &CLI.entry_data/1),
        "warnings" => Enum.map(warnings, &Error.warning/1)
      })
    else
      Mix.shell().info("Recipe #{result.root} (#{recipe.path})\n")
      Mix.shell().info(recipe.shortdoc <> "\n")

      if recipe.doc && String.trim(recipe.doc) != "",
        do: Mix.shell().info(String.trim(recipe.doc) <> "\n")

      if own != [] do
        Mix.shell().info("Flags:")
        Mix.shell().info(flag_table(own) <> "\n")
      end

      if used != [] do
        Mix.shell().info("Flags from used recipes:")
        Mix.shell().info(flag_table(used) <> "\n")
      end

      Mix.shell().info("Steps:")

      case result.steps do
        [] -> Mix.shell().info("  (no steps)")
        entries -> Mix.shell().info(CLI.render_entries(entries, aliases: true))
      end

      if result.duplicates != [] do
        Mix.shell().info("\nDuplicates dropped (first occurrence wins):")

        Enum.each(
          result.duplicates,
          &Mix.shell().info("  " <> CLI.render_entry(&1, aliases: true))
        )
      end

      CLI.print_warnings(warnings)
    end
  end

  defp flag_table(flags) do
    flags
    |> Enum.map(fn {flag, text} -> [CLI.switch(flag), text] end)
    |> CLI.table()
  end
end
