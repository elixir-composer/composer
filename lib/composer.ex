defmodule Composer do
  @moduledoc """
  Composable project setup for Elixir applications, built on
  [Igniter](https://hexdocs.pm/igniter).

  Composer turns your post-`phx.new` ritual into a **recipe**: an ordered,
  flag-aware list of **steps** that runs as one reviewable diff.

  ## Concepts

    * **Step** - a single unit of setup work, defined with
      `use Composer.Step`. Every step is an Igniter task, so steps compose
      into one diff and never blindly overwrite files. Steps are not Mix
      tasks, so they never show up in `mix help`. A step declares its
      metadata (summary, facets, tags, `requires`, ...) in one place; see
      `Composer.Step` and `Composer.Facets`.

    * **Cookbook** - one package's tree of steps, recipes and templates at
      `lib/composer/<package>/`, declared by `lib/composer/<package>.ex`
      (`use Composer.Cookbook`). A cookbook is named after its package.
      Composer ships the built-in `cb_std` cookbook, and any dependency with a
      cookbook is discovered automatically. See `Composer.Cookbook`.

    * **Recipe** - a named list of steps with a shortdoc, an optional doc
      and flags. Recipes live in chapters: `recipes/<chapter>.exs` holds the
      recipes `<cookbook>:<chapter>/<name>`. See `Composer.Recipe` and
      `Composer.Recipe.Chapter`.

    * **Reference** - the string `"cookbook:path"` that names a step or a
      recipe, e.g. `"cb_std:setup/credo"` or `"cc_lab:ash/postgres"`. An unqualified
      `"path"` is looked up in the referring recipe's own cookbook first,
      then everywhere; a name that matches no step is a Hex package
      (`"oban"` is `"hex:oban"`). See `Composer.Resolver`.

  ## Quick start

      mix composer.init                       # writes lib/composer/<app>/recipes/app.exs
      mix composer.recipe.run app/default    # runs its default recipe

  ## Recipe syntax

  A chapter file holds recipes keyed by name; `default` below is
  `<cookbook>:app/default`.

      # recipes/app.exs
      [
        default: [
          shortdoc: "My usual setup",
          flags: [oban_pro: "Add Oban Pro", gigalixir: "Deploy to Gigalixir"],
          steps: [
            "cb_std:phx/remove_daisy_ui",                  # a step
            "setup/credo",                               # an unqualified step reference
            "hex:oban",                                  # a Hex package and its installer
            {"cb_std:oban_pro", if: :oban_pro},            # only with --oban-pro
            {:use, "base"},                              # a recipe in this chapter, in place
            {:use, "cb_lab:deploy/gigalixir", if: :gigalixir},  # ... only with --gigalixir
            {:task, "ash.codegen", ["init"]},            # compose any Igniter task
            {:queue, "ecto.setup", []}                   # run a Mix task after changes apply
          ]
        ]
      ]

  Steps apply in list order, and every change lands in one diff you confirm
  once. The exception is dependencies: packages to install are added to
  `mix.exs` and fetched before any step runs, because their installers have
  to be on disk to compose. Queued tasks run last, non-interactively with
  `--yes`.

  ## Tasks

    * `mix composer.cookbook.list` / `.lint` / `.manifest`
    * `mix composer.step.list` / `.find` / `.help` / `.run`
    * `mix composer.recipe.list` / `.show` / `.run`
    * `mix composer.gen.cookbook` / `.step` / `.recipe`
    * `mix composer.index`, `mix composer.completion`
  """
end
