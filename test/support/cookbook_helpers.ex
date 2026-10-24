defmodule Composer.Test.Cookbooks do
  @moduledoc false
  # A code cookbook whose recipes live in a tmp dir, for tests that write
  # their own group files.

  alias Composer.{Cookbook, Lint, Manifest}

  @doc """
  A code cookbook named `name` reading `dir/recipes/*.exs`.

  It has no module of its own, so it has no steps: `app: :composer` finds
  no `Composer.Test.Mine.Steps.*` modules, and `Cookbook.source_dir/1`
  falls back to `dir` since `lib/composer/<name>` does not exist.
  """
  def code_cookbook(dir, name \\ "mine") do
    %Cookbook{
      name: name,
      kind: :code,
      app: :composer,
      module: Composer.Test.Mine,
      summary: "Test recipes in #{dir}",
      source_dir: dir
    }
  end

  @doc "The cookbooks of `apps` (and cb_std), then `code_cookbook(dir)`."
  def discover(dir, apps) do
    {:ok, cookbooks} =
      Composer.Discovery.cookbooks(apps: apps, cookbooks: [code_cookbook(dir)])

    cookbooks
  end

  @doc """
  Lints the recipes in `dir` as the cookbook `mine`, resolving against
  `cookbooks` plus it. Writes its manifest first, so only the recipes'
  own problems are reported.
  """
  def lint_recipes(dir, cookbooks) do
    book = code_cookbook(dir)
    File.write!(Manifest.path(book), Manifest.render(Manifest.build(book)))
    Lint.run(book, cookbooks ++ [book], dir)
  end
end
