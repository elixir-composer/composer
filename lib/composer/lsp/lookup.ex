defmodule Composer.LSP.Lookup do
  @moduledoc """
  Resolves what is under the cursor (`Composer.LSP.Cursor`) as a run
  would: against the buffer's context, the cookbook owning the buffer's
  file and the chapter path of the file (see `context/2`), with the
  recipe's aliases expanded. Shared by hover, goto-definition and
  completion.

  Results:

    * `{:step, meta}` - a step address
    * `{:recipe, recipe}` - a recipe address (an include), or the recipe
      whose name key is under the cursor, as a loaded `%Composer.Recipe{}`
    * `{:hex, package, :explicit}` - a `hex:` address
    * `{:alias, name, target}` - a cookbook alias name
    * `{:error, reason}` - an address that does not resolve
    * `nil` - nothing to resolve (a recipe key)
  """

  alias Composer.{Cookbook, Lint, Recipe, Ref, Resolver}
  alias Composer.Recipe.Chapter

  @type result ::
          {:step, Composer.Step.Meta.t()}
          | {:recipe, Recipe.t()}
          | {:hex, String.t(), :explicit}
          | {:alias, String.t(), String.t() | nil}
          | {:error, term()}
          | nil

  @doc """
  Resolves `cursor`, a hit in the buffer of the file at `path`, against
  the cookbooks of `snapshot` (`Composer.LSP.Workspace.snapshot/1`).
  """
  @spec resolve(Composer.LSP.Cursor.t() | nil, Path.t(), map()) :: result()
  def resolve(nil, _path, _snapshot), do: nil

  def resolve(cursor, path, snapshot) do
    cookbooks = cookbooks(snapshot)
    lookup(cursor, cookbooks, context(cookbooks, path))
  end

  @doc """
  The resolution context of a buffer (see `Composer.Resolver`): the
  cookbook whose `recipes/` holds the file at `path`, and the file's
  chapter path (`"ash/ui/tailwind"`), or `nil` for both.
  """
  @spec context([Cookbook.t()], Path.t()) :: Resolver.context()
  def context(cookbooks, path) do
    case Lint.owner(cookbooks, path) do
      {:ok, owner} ->
        recipes = owner |> Cookbook.source_dir() |> Path.join("recipes") |> Path.expand()
        file = Path.expand(path)

        chapter =
          if String.starts_with?(file, recipes <> "/"),
            do: Chapter.path(recipes, file),
            else: Chapter.path(file)

        %{cookbook: owner.name, chapter: chapter, cli?: false}

      {:error, _} ->
        %{cookbook: nil, chapter: nil, cli?: false}
    end
  end

  defp lookup(%{kind: :alias, value: name, aliases: aliases}, _cookbooks, _context) do
    name = to_string(name)
    {:alias, name, Map.get(aliases, name)}
  end

  defp lookup(%{kind: :ref, value: written} = cursor, cookbooks, context)
       when is_binary(written) do
    lookup = expand(written, cursor.aliases)

    case Ref.parse(lookup) do
      {:ok, %Ref{kind: :recipe}} ->
        with {:ok, id} <- Resolver.find_recipe(cookbooks, lookup, context),
             do: load(cookbooks, id)

      _ ->
        case Resolver.find_step(cookbooks, lookup, context) do
          {:ok, {:step, meta}} -> {:step, meta}
          {:ok, {:hex, package}} -> {:hex, package, :explicit}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lookup(%{kind: :recipe, value: name}, cookbooks, %{cookbook: own, chapter: chapter})
       when is_binary(own) and is_binary(chapter),
       do: load(cookbooks, Ref.id(:recipe, own, chapter <> "/" <> name))

  defp lookup(_cursor, _cookbooks, _context), do: nil

  @doc """
  The cookbooks a lookup resolves against: the snapshot's.
  """
  @spec cookbooks(map()) :: [Cookbook.t()]
  def cookbooks(%{cookbooks: cookbooks}), do: cookbooks

  defp load(cookbooks, id) do
    %Ref{cookbook: name, segments: segments} = ref = Ref.parse!(id)
    book = Enum.find(cookbooks, &(&1.name == name))

    case book && Cookbook.recipe_path(book, Ref.path(ref)) do
      path when is_binary(path) ->
        with {:ok, recipe} <- Recipe.load(path, name, List.last(segments)),
             do: {:recipe, recipe}

      _ ->
        {:error, {:missing_recipe, id, nil, []}}
    end
  end

  @doc """
  Replaces an aliased cookbook part of a qualified address `written` with
  the cookbook it names in `aliases` (`%{"lab" => "cc_lab"}`).
  """
  @spec expand(String.t(), %{String.t() => String.t()}) :: String.t()
  def expand(written, aliases) do
    with {:ok, %Ref{scope: :qualified, cookbook: name} = ref} <- Ref.parse(written),
         target when is_binary(target) <- Map.get(aliases, name) do
      Ref.to_string(%{ref | cookbook: target})
    else
      _ -> written
    end
  end
end
