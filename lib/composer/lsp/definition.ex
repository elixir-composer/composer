defmodule Composer.LSP.Definition do
  @moduledoc """
  Goto-definition targets and `hex:` document links.

    * a step: its source file, at its `use Composer.Step` line (a cookbook
      under `deps/` included)
    * a recipe: its name key in its chapter file
    * an alias: its entry in `aliases:`, or in the top-level binding that
      `aliases:` names
    * a `hex:` reference: a document link to its HexDocs
  """

  alias Composer.{Cookbook, Ref}
  alias Composer.Lint.Locate
  alias Composer.LSP.Cursor
  alias Composer.Recipe.Locator

  @type target :: {Path.t(), Composer.Lint.Diagnostic.range()}

  @doc """
  The target of a `Composer.LSP.Lookup` result, or `nil`. For an alias,
  `buffer` is `%{text, path, recipe}`, the buffer the cursor is in.
  """
  @spec target(Composer.LSP.Lookup.result(), [Cookbook.t()], map()) :: target() | nil
  def target({:step, meta}, cookbooks, _buffer) do
    with path when is_binary(path) <- step_source(meta, cookbooks) do
      {path, Locate.step_use(path) || Locator.first_line()}
    end
  end

  def target({:recipe, recipe}, _cookbooks, _buffer) do
    case Locator.index_file(recipe.path) do
      {:ok, index} -> {recipe.path, Locator.locate(index, recipe.name, :recipe)}
      {:error, _} -> {recipe.path, Locator.first_line()}
    end
  end

  def target({:alias, name, _target}, _cookbooks, %{text: text, path: path, recipe: recipe})
      when is_binary(recipe) do
    with {:ok, index} <- Locator.index(text, path),
         %{aliases: aliases} <- Locator.recipe(index, recipe),
         {_name, range} <- Enum.find(aliases, fn {atom, _} -> Atom.to_string(atom) == name end) do
      {path, range}
    else
      _ -> nil
    end
  end

  def target(_result, _cookbooks, _buffer), do: nil

  # The module's compiled source, else the file its id names under the
  # cookbook's steps/.
  defp step_source(meta, cookbooks) do
    Locate.source(meta.module) ||
      with %Cookbook{} = book <- Enum.find(cookbooks, &(&1.name == meta.cookbook)),
           dir when is_binary(dir) <- Cookbook.source_dir(book),
           path = Path.join([dir, "steps", meta.id <> ".ex"]),
           true <- File.regular?(path) do
        path
      else
        _ -> nil
      end
  end

  @doc """
  The `hex:` references in `text` as `{range, url}`, from the locator
  when the text parses, else by scanning each line's string literals.
  """
  @spec links(String.t(), Path.t()) :: [{Composer.Lint.Diagnostic.range(), String.t()}]
  def links(text, path) do
    literals =
      case Locator.index(text, path) do
        {:ok, index} ->
          for recipe <- index.recipes,
              {string, range} <- recipe.refs ++ recipe.uses,
              do: {string, range}

        {:error, _} ->
          for {line_text, line} <- Enum.with_index(String.split(text, ~r/\r?\n/), 1),
              %{end: end_column} = literal <- Cursor.literals(line_text),
              end_column != nil,
              do: {literal.value, {{line, literal.start}, {line, end_column}}}
      end

    for {string, range} <- Enum.uniq(literals),
        url = hexdocs(string),
        url != nil,
        do: {range, url}
  end

  @doc "The HexDocs URL of a `hex:` reference, or `nil`."
  @spec hexdocs(String.t()) :: String.t() | nil
  def hexdocs(string) do
    case Ref.parse(string) do
      {:ok, %Ref{cookbook: "hex", path: package}} ->
        case String.split(package, ".") do
          [org, name] -> "https://#{org}.hexdocs.pm/#{name}"
          [name] -> "https://hexdocs.pm/#{name}"
        end

      _ ->
        nil
    end
  end
end
