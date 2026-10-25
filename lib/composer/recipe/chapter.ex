defmodule Composer.Recipe.Chapter do
  @moduledoc """
  A chapter: one `recipes/**/*.exs` file holding one or more recipes,
  keyed by name.

      # recipes/ash.exs
      [
        base: [
          shortdoc: "Ash core: sourceror, ash and ash_phoenix",
          steps: ["cc_lab:sourceror", "cc_lab:ash", "cc_lab:ash/phoenix"]
        ],
        ecto: [
          shortdoc: "Ash with the Postgres data layer",
          steps: [{:use, "base"}, "cc_lab:ash/postgres"]
        ]
      ]

  A chapter's **path** is its file's path under `recipes/` without
  `.exs`, so `ecto` above is `<cookbook>:ash/ecto`, and a recipe in
  `recipes/ash/ui/tailwind.exs` is `<cookbook>:ash/ui/tailwind/<name>`.
  `recipes/ash/ui.exs` and the directory `recipes/ash/ui/` may coexist: the
  last segment of a recipe id is always its name. Every directory, chapter
  and recipe name is a lowercase `[a-z0-9_]` segment.

  ## Reading without evaluating

  `ids/1` reads the recipe names from the file's syntax tree, without
  running it, so listing and completion never evaluate a chapter. That is why
  the file must end in a **literal** keyword list (`[name: [...], ...]`).
  Bindings before it are fine; the values may be any expression.

  The bindings are also how recipes in a chapter share settings, such as
  cookbook aliases (see `Composer.Recipe`):

      # recipes/auth.exs
      aliases = [lab: "cc_lab"]

      [
        passkeys: [
          shortdoc: "Passkey sign-in",
          aliases: aliases,
          steps: ["lab:auth/passkeys"]
        ],
        magic: [
          shortdoc: "Magic-link sign-in",
          aliases: aliases,
          steps: ["lab:auth/magic_link"]
        ]
      ]

  `load/2` evaluates the file once and validates every recipe in it (see
  `Composer.Recipe` for the keys). A problem with the file as a whole (its
  shape, a duplicate name) makes every recipe in it unusable; a problem
  with one recipe only affects that recipe (see `load_all/2`).
  """

  alias Composer.Recipe

  @segment ~r/\A[a-z0-9_]+\z/
  @keys [:shortdoc, :doc, :flags, :aliases, :steps]
  @required [:shortdoc, :steps]

  @doc "True for a valid recipe name, or one segment of a chapter path."
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@segment, name)

  @doc "True for a valid chapter path: `/`-separated valid names."
  @spec valid_path?(String.t()) :: boolean()
  def valid_path?(path) when is_binary(path),
    do: path |> String.split("/") |> Enum.all?(&valid_name?/1)

  @doc """
  The chapter path of chapter file `file` under `recipes_dir`: its relative
  path without `.exs`, e.g. `"ash/ui/tailwind"`.
  """
  @spec path(Path.t(), Path.t()) :: String.t()
  def path(recipes_dir, file),
    do: file |> Path.relative_to(recipes_dir) |> Path.rootname(".exs")

  @doc """
  The chapter path of chapter file `file`, found from its place in a
  cookbook (`lib/composer/<cookbook>/recipes/...`, or else the last
  `recipes/` directory on its path), or its base name without `.exs` for a
  file outside one.
  """
  @spec path(Path.t()) :: String.t()
  def path(file) do
    expanded = Path.expand(file)

    case Regex.run(~r{/composer/[a-z0-9_]+/recipes/(.+)\.exs\z}, expanded,
           capture: :all_but_first
         ) do
      [chapter] ->
        chapter

      nil ->
        case String.split(expanded, "/recipes/") do
          [_] -> Path.basename(file, ".exs")
          parts -> parts |> List.last() |> Path.rootname(".exs")
        end
    end
  end

  @doc """
  Returns the recipe names in a chapter file, in file order, read from its
  syntax tree. Duplicates are kept; see `duplicates/1`.
  """
  @spec names(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def names(path) do
    with {:ok, content} <- read(path), do: names(content, path)
  end

  @doc "Like `names/1`, for a chapter file's source; `path` words errors."
  @spec names(String.t(), Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def names(content, path) do
    with {:ok, quoted} <- parse(content, path) do
      case literal_keys(last_expression(quoted)) do
        {:ok, keys} -> {:ok, Enum.map(keys, &Atom.to_string/1)}
        :error -> {:error, {:chapter_shape, path, :not_literal}}
      end
    end
  end

  @doc "Like `names/1`, sorted and without duplicates."
  @spec ids(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def ids(path) do
    with {:ok, names} <- names(path), do: {:ok, names |> Enum.uniq() |> Enum.sort()}
  end

  @doc "Returns the names that appear more than once in `names`."
  @spec duplicates([String.t()]) :: [String.t()]
  def duplicates(names) do
    names |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) > 1)) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Evaluates and validates the chapter file at `path`, in cookbook `cookbook`,
  returning its recipes in file order. The first problem found is returned
  as the error; `check/3` returns all of them.
  """
  @spec load(Path.t(), String.t()) :: {:ok, [Recipe.t()]} | {:error, term()}
  def load(path, cookbook) do
    case load_all(path, cookbook) do
      {:ok, {recipes, []}} -> {:ok, recipes}
      {:ok, {_recipes, [error | _]}} -> {:error, error}
      error -> error
    end
  end

  @doc """
  Evaluates the chapter file at `path` and returns its valid recipes and
  the problems of the others. A problem with the file as a whole is an
  error.
  """
  @spec load_all(Path.t(), String.t()) :: {:ok, {[Recipe.t()], [term()]}} | {:error, term()}
  def load_all(path, cookbook) do
    with {:ok, term} <- eval(path, cookbook) do
      case check(term, path, cookbook) do
        {recipes, errors} ->
          case Enum.find(errors, &file_error?/1) do
            nil -> {:ok, {recipes, errors}}
            error -> {:error, error}
          end
      end
    end
  end

  @doc """
  Picks recipe `name` from the result of `load_all/2`: the recipe, or the
  first problem found with it.
  """
  @spec pick({[Recipe.t()], [term()]}, Path.t(), String.t(), String.t()) ::
          {:ok, Recipe.t()} | {:error, term()}
  def pick({recipes, errors}, path, cookbook, name) do
    ref = Composer.Ref.Legacy.id(cookbook, path(path) <> "/" <> name)

    cond do
      recipe = Enum.find(recipes, &(&1.name == name)) ->
        {:ok, recipe}

      error = Enum.find(errors, &(elem(&1, 1) == ref)) ->
        {:error, error}

      error = Enum.find(errors, &match?({:invalid_recipe_name, _, n} when n == name, &1)) ->
        {:error, error}

      true ->
        {:error, {:missing_recipe, ref, nil, []}}
    end
  end

  defp file_error?(error),
    do: elem(error, 0) in [:chapter_shape, :invalid_chapter_path, :duplicate_recipe]

  @doc """
  Validates an evaluated chapter term. Returns the valid recipes and every
  problem found, as error reasons for `Composer.Error.message/1`.
  """
  @spec check(term(), Path.t(), String.t()) :: {[Recipe.t()], [term()]}
  def check(term, path, cookbook) do
    {recipes, errors} = check_tagged(term, path, cookbook)
    {recipes, Enum.map(errors, &elem(&1, 0))}
  end

  @doc """
  Like `check/3`, with each problem as `{reason, recipe_ref}`: the recipe
  it was found in, or `nil` for a problem with the file as a whole.
  """
  @spec check_tagged(term(), Path.t(), String.t()) ::
          {[Recipe.t()], [{term(), String.t() | nil}]}
  def check_tagged(term, path, cookbook) do
    chapter = path(path)

    cond do
      not valid_path?(chapter) ->
        {[], [{{:invalid_chapter_path, path}, nil}]}

      not (is_list(term) and Keyword.keyword?(term)) ->
        {[], [{{:chapter_shape, path, term}, nil}]}

      true ->
        duplicates =
          for name <- term |> Keyword.keys() |> Enum.map(&Atom.to_string/1) |> duplicates(),
              do: {{:duplicate_recipe, path, name}, nil}

        {recipes, errors} =
          term
          |> Enum.uniq_by(&elem(&1, 0))
          |> Enum.map(fn {name, value} -> recipe(cookbook, chapter, name, value, path) end)
          |> Enum.split_with(&match?({:ok, _}, &1))

        errors = for {:error, ref, reasons} <- errors, reason <- reasons, do: {reason, ref}
        {Enum.map(recipes, &elem(&1, 1)), duplicates ++ errors}
    end
  end

  defp recipe(cookbook, chapter, name, value, path) do
    id = "#{chapter}/#{name}"
    ref = Composer.Ref.Legacy.id(cookbook, id)

    errors =
      cond do
        not valid_name?(Atom.to_string(name)) -> [{:invalid_recipe_name, path, name}]
        not (is_list(value) and Keyword.keyword?(value)) -> [{:recipe_shape, ref, value}]
        true -> keys(value, ref)
      end

    case errors do
      [] ->
        {:ok,
         %Recipe{
           id: id,
           ref: ref,
           cookbook: cookbook,
           chapter: chapter,
           name: Atom.to_string(name),
           path: path,
           shortdoc: value[:shortdoc],
           doc: value[:doc],
           flags: Keyword.get(value, :flags, []),
           aliases: Keyword.get(value, :aliases, []),
           steps: value[:steps]
         }}

      errors ->
        {:error, ref, errors}
    end
  end

  defp keys(value, ref) do
    unknown =
      for {key, _} <- value, key not in @keys, uniq: true, do: {:unknown_recipe_key, ref, key}

    missing =
      for key <- @required, not Keyword.has_key?(value, key), do: {:recipe_missing_key, ref, key}

    bad =
      for {key, v} <- value,
          key in @keys,
          not value?(key, v),
          do: {:bad_recipe_value, ref, key, v}

    steps =
      case value[:steps] do
        steps when is_list(steps) ->
          case for(entry <- steps, reason = Recipe.entry_error(entry, ref), do: reason) do
            [] -> undeclared(steps, value[:flags], ref) ++ reserved(value[:flags], ref)
            reasons -> reasons
          end

        _ ->
          []
      end

    aliases =
      case value[:aliases] do
        aliases when is_list(aliases) ->
          if Keyword.keyword?(aliases), do: Recipe.validate_aliases(aliases, ref), else: []

        _ ->
          []
      end

    unknown ++ missing ++ bad ++ aliases ++ steps
  end

  defp value?(:shortdoc, v), do: is_binary(v) and String.trim(v) != ""
  defp value?(:doc, v), do: is_binary(v)
  defp value?(:steps, v), do: is_list(v)
  defp value?(:aliases, v), do: is_list(v) and Keyword.keyword?(v)

  defp value?(:flags, v) do
    is_list(v) and Keyword.keyword?(v) and
      Enum.all?(v, fn {flag, text} -> Recipe.flag?(flag) and is_binary(text) end)
  end

  # Every if: flag in a recipe's own steps must be in its own flags.
  defp undeclared(steps, flags, ref) do
    declared = if is_list(flags) and Keyword.keyword?(flags), do: Keyword.keys(flags), else: []
    for flag <- Recipe.if_flags(steps), flag not in declared, do: {:undeclared_flag, ref, flag}
  end

  # No recipe may declare a flag that the commands passing flags through to
  # it use themselves (Composer.Recipe.reserved_flags/0).
  defp reserved(flags, ref) do
    declared = if is_list(flags) and Keyword.keyword?(flags), do: Keyword.keys(flags), else: []
    reserved = Recipe.reserved_flags()
    for flag <- Enum.uniq(declared), flag in reserved, do: {:reserved_flag, ref, flag}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:chapter_read, path, reason}}
    end
  end

  defp parse(content, path) do
    case Code.string_to_quoted(content, file: path) do
      {:ok, quoted} ->
        {:ok, quoted}

      {:error, {location, message, token}} ->
        {:error, {:chapter_parse, path, text(message) <> text(token), location_line(location)}}
    end
  end

  defp location_line(location) when is_list(location), do: location[:line]
  defp location_line(line) when is_integer(line), do: line
  defp location_line(_location), do: nil

  defp text({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp text(text), do: to_string(text)

  defp last_expression({:__block__, _, [_ | _] = exprs}), do: List.last(exprs)
  defp last_expression(quoted), do: quoted

  defp literal_keys(list) when is_list(list) do
    if Enum.all?(list, &match?({key, _} when is_atom(key), &1)),
      do: {:ok, Enum.map(list, &elem(&1, 0))},
      else: :error
  end

  defp literal_keys(_quoted), do: :error

  @doc false
  # Evaluates a chapter file. A failure records the line in that file where
  # it happened, when there is one: the parser's, or the stacktrace's.
  def eval(path, cookbook) do
    {term, _binding} = Code.eval_file(path)
    {:ok, term}
  rescue
    exception ->
      line = eval_line(exception, __STACKTRACE__, path)
      {:error, {:recipe_eval, "#{cookbook}:#{path(path)}/", path, exception, line}}
  end

  defp eval_line(exception, stacktrace, path) do
    expanded = Path.expand(path)
    same? = &(is_binary(&1) and Path.expand(&1) == expanded)

    case exception do
      %{file: file, line: line} when is_integer(line) ->
        if same?.(file), do: line

      _ ->
        Enum.find_value(stacktrace, fn {_m, _f, _a, location} ->
          file = location[:file] && to_string(location[:file])
          if same?.(file), do: location[:line]
        end)
    end
  end
end
