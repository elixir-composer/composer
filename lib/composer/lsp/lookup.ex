defmodule Composer.LSP.Lookup do
  @moduledoc """
  Resolves what is under the cursor (`Composer.LSP.Cursor`) as a run
  would: the recipe's aliases are expanded, and the cookbook owning the
  buffer's file is the context unqualified references are looked up in
  first. Shared by hover and goto-definition.

  Results:

    * `{:step, meta}` - a step reference
    * `{:recipe, recipe}` - a `{:use, ...}` target, or the recipe whose
      name key is under the cursor, as a loaded `%Composer.Recipe{}`
    * `{:hex, package, :explicit | :fallthrough}` - a `hex:` reference,
      or an unqualified name no cookbook has as a step
    * `{:alias, name, target}` - a cookbook alias name
    * `{:error, reason}` - a reference that does not resolve
    * `nil` - nothing to resolve (a recipe key)
  """

  alias Composer.{Cookbook, Lint, Local, Recipe, Ref, Resolver}

  @type result ::
          {:step, Composer.Step.Meta.t()}
          | {:recipe, Recipe.t()}
          | {:hex, String.t(), :explicit | :fallthrough}
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
    owner = owner(cookbooks, path, snapshot)
    resolve(cursor, cookbooks, owner, Path.basename(path, ".exs"))
  end

  defp resolve(%{kind: :alias, value: name, aliases: aliases}, _cookbooks, _owner, _group) do
    name = to_string(name)
    {:alias, name, Map.get(aliases, name)}
  end

  defp resolve(%{kind: :ref, value: written} = cursor, cookbooks, owner, _group)
       when is_binary(written) do
    case Resolver.find_step(cookbooks, expand(written, cursor.aliases), owner && owner.name) do
      {:ok, {:step, meta}} -> {:step, meta}
      {:ok, {:hex, package}} -> {:hex, package, hex_kind(written)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve(%{kind: :use, value: written} = cursor, cookbooks, owner, group)
       when is_binary(written) do
    context = owner && owner.name

    found =
      case Ref.parse(written) do
        {:ok, %Ref{cookbook: nil} = ref} when context != nil ->
          if Ref.grouped?(ref),
            do: Resolver.find_recipe(cookbooks, written, context),
            else: in_group(cookbooks, context, group, written)

        _ ->
          Resolver.find_recipe(cookbooks, expand(written, cursor.aliases), context)
      end

    with {:ok, id} <- found, do: load(cookbooks, id)
  end

  defp resolve(%{kind: :recipe, value: name}, cookbooks, owner, group) when owner != nil,
    do: load(cookbooks, Ref.id(owner.name, group <> "/" <> name))

  defp resolve(_cursor, _cookbooks, _owner, _group), do: nil

  @doc """
  The cookbooks a lookup resolves against: the snapshot's code cookbooks
  and local, built from its directory (which may not exist).
  """
  @spec cookbooks(map()) :: [Cookbook.t()]
  def cookbooks(%{cookbooks: cookbooks, local_dir: nil}), do: cookbooks

  def cookbooks(%{cookbooks: cookbooks, local_dir: dir}),
    do: Enum.reject(cookbooks, &(&1.kind == :local)) ++ [Local.build(Path.expand(dir))]

  defp owner(cookbooks, path, snapshot) do
    case Lint.owner(cookbooks, path, local: snapshot.local_dir) do
      {:ok, owner} -> owner
      {:error, _} -> nil
    end
  end

  # An unqualified {:use, "name"} is the recipe `name` in the same group.
  defp in_group(cookbooks, context, group, name) do
    id = group <> "/" <> name
    book = Enum.find(cookbooks, &(&1.name == context))

    if book && id in Cookbook.recipes(book),
      do: {:ok, Ref.id(context, id)},
      else: {:error, {:missing_recipe, name, nil, []}}
  end

  defp load(cookbooks, id) do
    %Ref{cookbook: name, path: recipe_id} = Ref.parse!(id)
    book = Enum.find(cookbooks, &(&1.name == name))

    case book && Cookbook.recipe_path(book, recipe_id) do
      path when is_binary(path) ->
        with {:ok, recipe} <- Recipe.load(path, name, Path.basename(recipe_id)),
             do: {:recipe, recipe}

      _ ->
        {:error, {:missing_recipe, id, nil, []}}
    end
  end

  @doc """
  Replaces an aliased cookbook part of `written` with the cookbook it
  names in `aliases` (`%{"lab" => "cc_lab"}`).
  """
  @spec expand(String.t(), %{String.t() => String.t()}) :: String.t()
  def expand(written, aliases) do
    with {:ok, %Ref{cookbook: name, path: path}} when is_binary(name) <- Ref.parse(written),
         target when is_binary(target) <- Map.get(aliases, name) do
      Ref.id(target, path)
    else
      _ -> written
    end
  end

  defp hex_kind(written) do
    case Ref.parse(written) do
      {:ok, %Ref{cookbook: "hex"}} -> :explicit
      _ -> :fallthrough
    end
  end
end
