defmodule Composer.LSP.Diagnostics do
  @moduledoc """
  The diagnostics of a saved recipe group file and of the files that
  include its recipes, from disk.

  The file's recipes are read with `Composer.Recipe.Locator` (so even a
  file that does not evaluate names them), their dependents found with
  `Composer.Lint.dependents/3`, and everything linted in one pass with
  `Composer.Lint.files/3`, given what `mix composer.cookbook.lint --file`
  gives it, so the results are the same.

  The dependents linted last time are linted again, so a file that no
  longer includes the saved one (or that was fixed by the save) has its
  diagnostics cleared.
  """

  alias Composer.{Lint, Ref}
  alias Composer.Recipe.Locator

  @type args :: %{
          cookbooks: [Composer.Cookbook.t()],
          local_dir: Path.t() | nil,
          root: Path.t() | nil,
          known_dependents: [Path.t()]
        }

  @doc """
  Lints `path` and its dependents. Returns `:ignore` for a file that is
  not a recipe group, or `{:ok, %{path => diagnostics}, dependents}`.
  """
  @spec run(Path.t(), args()) ::
          :ignore | {:ok, %{Path.t() => [Composer.Lint.Diagnostic.t()]}, [Path.t()]}
  def run(path, args) do
    opts = [local: args.local_dir]

    case Lint.owner(args.cookbooks, path, opts) do
      {:ok, owner} ->
        found =
          case refs(owner, path) do
            [] ->
              []

            refs ->
              for %{path: dependent} <- Lint.dependents(args.cookbooks, refs, opts), do: dependent
          end

        dependents =
          (found ++ Enum.filter(Map.get(args, :known_dependents, []), &File.regular?/1))
          |> Enum.uniq()
          |> List.delete(path)

        results = Lint.files(args.cookbooks, [path | dependents], opts ++ [root: args.root])
        {:ok, results, dependents}

      {:error, _not_a_recipe_file} ->
        :ignore
    end
  end

  # The refs of the recipes written in the file, read without evaluating it.
  defp refs(owner, path) do
    group = Path.basename(path, ".exs")

    case Locator.index_file(path) do
      {:ok, index} ->
        for recipe <- index.recipes,
            uniq: true,
            do: Ref.id(owner.name, group <> "/" <> recipe.name)

      {:error, _} ->
        []
    end
  end
end
