defmodule Composer.Recipe.Locator do
  @moduledoc """
  Finds where things are written in a chapter file, without
  evaluating it.

  `index/2` parses a chapter's source and records, for each recipe in the
  final keyword list:

    * `key` - the range of its name key (`auth:`)
    * `keys` - its own keys (`steps:`, `aliases:`, `flags:`, ...)
    * `refs` - the reference strings in its `steps:`, in source order,
      including the string of a `{"ref", opts}` entry
    * `uses` - the strings of its `{:use, ...}` entries
    * `entries` - each entry's range and, when it is literal, its value
    * `aliases` - each alias name, from a literal `aliases:` or from the
      top-level binding that `aliases:` names
    * `alias_targets` - each alias's target, where it is a literal string
    * `ifs` - each `if:` flag atom

  Top-level `name = ...` bindings are recorded too, and a `steps:` or
  `aliases:` that names one is read through it.

  Positions follow `Composer.Lint.Diagnostic`: 1-based lines, columns
  counted in characters as Elixir's tokenizer counts them, and ranges
  `{{line, column}, {end_line, end_column}}` with an exclusive end. The
  index keeps each line's text (`line/2`), so a caller needing another
  column unit (an LSP's UTF-16) can convert without parsing again.

  `locate/3` answers "where is this?" and always returns a range,
  falling back from the literal to the recipe's `steps:` key, to its name
  key, to line 1. `at/3` answers "what is here?".
  """

  defstruct [:path, lines: {}, recipes: [], bindings: %{}]

  @type range :: Composer.Lint.Diagnostic.range()

  @type recipe :: %{
          name: String.t(),
          key: range(),
          keys: %{atom() => range()},
          refs: [{String.t(), range()}],
          uses: [{String.t(), range()}],
          entries: [{range(), term()}],
          aliases: %{atom() => range()},
          alias_targets: %{atom() => String.t()},
          ifs: %{atom() => range()}
        }

  @type t :: %__MODULE__{
          path: Path.t(),
          lines: tuple(),
          recipes: [recipe()],
          bindings: %{atom() => range()}
        }

  @type target ::
          :recipe
          | {:ref, String.t() | (String.t() -> boolean())}
          | {:use, String.t()}
          | {:entry, term()}
          | {:key, atom()}
          | {:if, atom()}
          | {:alias, atom()}

  @parse_opts [
    columns: true,
    token_metadata: true,
    literal_encoder: &__MODULE__.encode_literal/2
  ]

  @doc false
  def encode_literal(literal, meta), do: {:ok, {:__block__, meta, [literal]}}

  @doc """
  Indexes a chapter file's `source`; `path` is recorded and words errors.
  Returns `{:error, {:chapter_parse, path, description, line}}` when the
  source does not parse.
  """
  @spec index(String.t(), Path.t()) :: {:ok, t()} | {:error, term()}
  def index(source, path) do
    case Code.string_to_quoted(source, [file: path] ++ @parse_opts) do
      {:ok, quoted} ->
        {:ok, build(quoted, source, path)}

      {:error, {location, message, token}} ->
        {:error, {:chapter_parse, path, text(message) <> text(token), location_line(location)}}
    end
  end

  @doc "Reads and indexes the chapter file at `path`."
  @spec index_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def index_file(path) do
    case File.read(path) do
      {:ok, source} -> index(source, path)
      {:error, reason} -> {:error, {:chapter_read, path, reason}}
    end
  end

  @doc "The parse options the locator uses, for parsing other files alike."
  @spec parse_opts() :: keyword()
  def parse_opts, do: @parse_opts

  @doc "Returns line `n`'s text (without its newline), or `nil`."
  @spec line(t(), pos_integer()) :: String.t() | nil
  def line(%__MODULE__{lines: lines}, n) when n >= 1 and n <= tuple_size(lines),
    do: elem(lines, n - 1)

  def line(%__MODULE__{}, _n), do: nil

  @doc "Returns the indexed recipe named `name` (the first, if duplicated)."
  @spec recipe(t(), String.t()) :: recipe() | nil
  def recipe(%__MODULE__{recipes: recipes}, name), do: Enum.find(recipes, &(&1.name == name))

  @doc "Returns the ranges of every name key `name`, in file order."
  @spec recipe_keys(t(), String.t()) :: [range()]
  def recipe_keys(%__MODULE__{recipes: recipes}, name),
    do: for(%{name: ^name, key: key} <- recipes, do: key)

  @doc """
  Returns the ranges of the reference strings (in `steps:` and
  `{:use, ...}`) of recipe `name` that equal `match`, or satisfy it when
  it is a function, in source order.
  """
  @spec refs(t(), String.t(), String.t() | (String.t() -> boolean())) :: [range()]
  def refs(index, name, match) do
    case recipe(index, name) do
      nil -> []
      recipe -> for {string, range} <- literals(recipe), matches?(match, string), do: range
    end
  end

  @doc """
  Returns the most precise range for `target` in recipe `name`. When
  `target` cannot be found, falls back to the recipe's `steps:` key (or,
  for an alias, its `aliases:`), then its name key, then line 1.
  """
  @spec locate(t(), String.t(), target()) :: range()
  def locate(%__MODULE__{} = index, name, target) do
    case recipe(index, name) do
      nil -> first_line()
      recipe -> find(index, recipe, target) || recipe.key
    end
  end

  @doc """
  Returns what is at `line`, `column`: a reference, a `{:use, ...}`
  target, an alias name, a recipe key or a recipe's name key, as
  `{kind, recipe_name, value, range}`, or `nil`.
  """
  @spec at(t(), pos_integer(), pos_integer()) ::
          {:ref | :use | :alias | :key | :recipe, String.t(), term(), range()} | nil
  def at(%__MODULE__{recipes: recipes}, line, column) do
    Enum.find_value(recipes, fn recipe ->
      [{:recipe, recipe.name, recipe.key}]
      |> Enum.concat(for {key, range} <- recipe.keys, do: {:key, key, range})
      |> Enum.concat(for {string, range} <- recipe.refs, do: {:ref, string, range})
      |> Enum.concat(for {string, range} <- recipe.uses, do: {:use, string, range})
      |> Enum.concat(for {name, range} <- recipe.aliases, do: {:alias, name, range})
      |> Enum.find_value(fn {kind, value, range} ->
        if within?(range, {line, column}), do: {kind, recipe.name, value, range}
      end)
    end)
  end

  @doc "The range used when nothing better is known: the start of line 1."
  @spec first_line() :: range()
  def first_line, do: {{1, 1}, {1, 1}}

  # -- lookups ----------------------------------------------------------------

  defp find(_index, recipe, :recipe), do: recipe.key

  defp find(_index, recipe, {:ref, match}) do
    Enum.find_value(literals(recipe), fn {string, range} -> matches?(match, string) && range end) ||
      recipe.keys[:steps]
  end

  defp find(_index, recipe, {:use, string}) do
    Enum.find_value(recipe.uses, fn {s, range} -> s == string && range end) ||
      recipe.keys[:steps]
  end

  defp find(_index, recipe, {:entry, entry}) do
    first = first_string(entry)

    Enum.find_value(recipe.entries, fn {range, value} -> value == entry && range end) ||
      (first && find(nil, recipe, {:ref, first})) || recipe.keys[:steps]
  end

  defp find(_index, recipe, {:key, key}), do: recipe.keys[key]
  defp find(_index, recipe, {:if, flag}), do: recipe.ifs[flag] || recipe.keys[:steps]

  defp find(_index, recipe, {:alias, name}),
    do: recipe.aliases[name] || recipe.keys[:aliases]

  defp literals(recipe), do: Enum.sort_by(recipe.refs ++ recipe.uses, &elem(&1, 1))

  defp matches?(match, string) when is_function(match, 1), do: match.(string)
  defp matches?(match, string), do: match == string

  defp first_string(string) when is_binary(string), do: string

  defp first_string(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.find_value(&first_string/1)

  defp first_string(list) when is_list(list), do: Enum.find_value(list, &first_string/1)
  defp first_string(_term), do: nil

  defp within?({from, to}, position), do: position >= from and position < to

  # -- building the index -----------------------------------------------------

  defp build(quoted, source, path) do
    lines = source |> String.split(~r/\r?\n/) |> List.to_tuple()
    exprs = expressions(quoted)
    {init, [last]} = Enum.split(exprs, -1)

    bindings =
      for {:=, _, [{var, meta, context}, value]} <- init,
          is_atom(var) and is_atom(context),
          into: %{},
          do: {var, {meta, value}}

    ctx = %{lines: lines, bindings: bindings}

    recipes =
      case unwrap(last) do
        {:list, items} ->
          for {key_ast, value} <- items, {:ok, name} <- [key_atom(key_ast)] do
            recipe(ctx, Atom.to_string(name), key_range(ctx, key_ast), value)
          end

        _ ->
          []
      end

    %__MODULE__{
      path: path,
      lines: lines,
      recipes: recipes,
      bindings: Map.new(bindings, fn {var, {meta, _}} -> {var, name_range(meta, var)} end)
    }
  end

  # A file of several expressions is a block without position; one
  # expression (even a literal list) is the expression itself.
  defp expressions({:__block__, [], exprs}) when is_list(exprs) and exprs != [], do: exprs
  defp expressions(quoted), do: [quoted]

  defp recipe(ctx, name, key, value) do
    base = %{
      name: name,
      key: key,
      keys: %{},
      refs: [],
      uses: [],
      entries: [],
      aliases: %{},
      alias_targets: %{},
      ifs: %{}
    }

    case unwrap(resolve(ctx, value)) do
      {:list, pairs} ->
        Enum.reduce(pairs, base, fn
          {key_ast, value}, acc ->
            case key_atom(key_ast) do
              {:ok, key} -> recipe_key(ctx, acc, key, key_range(ctx, key_ast), value)
              :error -> acc
            end

          _other, acc ->
            acc
        end)

      _ ->
        base
    end
  end

  defp recipe_key(ctx, acc, key, range, value) do
    acc = %{acc | keys: Map.put_new(acc.keys, key, range)}

    case key do
      :steps -> steps(ctx, acc, value)
      :aliases -> aliases(ctx, acc, value)
      _ -> acc
    end
  end

  defp steps(ctx, acc, value) do
    case unwrap(resolve(ctx, value)) do
      {:list, items} ->
        items
        |> Enum.reduce(acc, &entry(ctx, &1, &2))
        |> then(&%{&1 | refs: Enum.reverse(&1.refs), uses: Enum.reverse(&1.uses)})
        |> then(&%{&1 | entries: Enum.reverse(&1.entries)})

      _ ->
        acc
    end
  end

  defp entry(ctx, ast, acc) do
    acc =
      case ast do
        {:__block__, _, [string]} when is_binary(string) ->
          %{acc | refs: [{string, string_range(ctx, ast)} | acc.refs]}

        {:__block__, _, [{first, second}]} ->
          tuple(ctx, acc, [first, second])

        {:{}, _, elements} ->
          tuple(ctx, acc, elements)

        _ ->
          acc
      end

    case {literal(ast), node_range(ctx, ast)} do
      {{:ok, value}, range} when range != nil -> %{acc | entries: [{range, value} | acc.entries]}
      _ -> acc
    end
  end

  defp tuple(ctx, acc, [{:__block__, _, [:use]}, {:__block__, _, [string]} = ref | rest])
       when is_binary(string) do
    acc = %{acc | uses: [{string, string_range(ctx, ref)} | acc.uses]}
    ifs(ctx, acc, rest)
  end

  defp tuple(ctx, acc, [{:__block__, _, [string]} = ref | rest]) when is_binary(string) do
    acc = %{acc | refs: [{string, string_range(ctx, ref)} | acc.refs]}
    ifs(ctx, acc, rest)
  end

  defp tuple(ctx, acc, [_kind | rest]), do: ifs(ctx, acc, rest)

  defp ifs(ctx, acc, elements) do
    for element <- elements,
        {:list, pairs} <- [unwrap(element)],
        {key_ast, {:__block__, _, [flag]} = value} <- pairs,
        key_atom(key_ast) == {:ok, :if},
        is_atom(flag),
        reduce: acc do
      acc -> %{acc | ifs: Map.put_new(acc.ifs, flag, atom_range(ctx, value))}
    end
  end

  # Alias names, from a literal list or the binding a variable names; the
  # binding itself when its value is not literal.
  defp aliases(ctx, acc, {var, meta, nil} = value) when is_atom(var) and is_list(meta) do
    case ctx.bindings[var] do
      {binding_meta, bound} ->
        case alias_names(ctx, bound) do
          names when names != %{} -> %{acc | aliases: names, alias_targets: alias_targets(bound)}
          _ -> %{acc | keys: Map.put(acc.keys, :aliases, name_range(binding_meta, var))}
        end

      nil ->
        aliases_literal(ctx, acc, value)
    end
  end

  defp aliases(ctx, acc, value), do: aliases_literal(ctx, acc, value)

  defp aliases_literal(ctx, acc, value),
    do: %{acc | aliases: alias_names(ctx, value), alias_targets: alias_targets(value)}

  defp alias_names(ctx, value) do
    case unwrap(value) do
      {:list, pairs} ->
        for {key_ast, _} <- pairs, {:ok, name} <- [key_atom(key_ast)], reduce: %{} do
          names -> Map.put_new(names, name, key_range(ctx, key_ast))
        end

      _ ->
        %{}
    end
  end

  defp alias_targets(value) do
    case unwrap(value) do
      {:list, pairs} ->
        for {key_ast, {:__block__, _, [target]}} <- pairs,
            is_binary(target),
            {:ok, name} <- [key_atom(key_ast)],
            reduce: %{} do
          targets -> Map.put_new(targets, name, target)
        end

      _ ->
        %{}
    end
  end

  defp resolve(ctx, {var, meta, nil} = ast) when is_atom(var) and is_list(meta) do
    case ctx.bindings[var] do
      {_meta, value} -> value
      nil -> ast
    end
  end

  defp resolve(_ctx, ast), do: ast

  # A list literal; keywords at the end of a tuple or call are a bare list.
  defp unwrap({:__block__, _, [list]}) when is_list(list), do: {:list, list}
  defp unwrap(list) when is_list(list), do: {:list, list}
  defp unwrap(_ast), do: :error

  defp key_atom({:__block__, meta, [key]}) when is_atom(key) do
    if meta[:format] == :keyword, do: {:ok, key}, else: :error
  end

  defp key_atom(_ast), do: :error

  # -- ranges -----------------------------------------------------------------

  defp key_range(_ctx, {:__block__, meta, [key]}) do
    {line, column} = {meta[:line], meta[:column]}
    {{line, column}, {line, column + String.length(Atom.to_string(key)) + 1}}
  end

  defp name_range(meta, var) do
    {line, column} = {meta[:line], meta[:column]}
    {{line, column}, {line, column + String.length(Atom.to_string(var))}}
  end

  defp atom_range(_ctx, {:__block__, meta, [atom]}) do
    {line, column} = {meta[:line], meta[:column]}
    {{line, column}, {line, column + String.length(inspect(atom))}}
  end

  @doc false
  # The source length of a string literal, quotes included: escapes make
  # it differ from the value's length. `ctx` holds the source's `lines`.
  def string_range(ctx, {:__block__, meta, [string]}) do
    {line, column} = {meta[:line], meta[:column]}

    end_column =
      with "\"" <- meta[:delimiter],
           text when is_binary(text) <- line_text(ctx, line),
           ["\"" | rest] <- text |> String.graphemes() |> Enum.drop(column - 1),
           {:ok, length} <- closing_quote(rest, 1) do
        column + length
      else
        _ -> column + String.length(inspect(string))
      end

    {{line, column}, {line, end_column}}
  end

  defp closing_quote(["\\", _ | rest], n), do: closing_quote(rest, n + 2)
  defp closing_quote(["\"" | _], n), do: {:ok, n + 1}
  defp closing_quote([_ | rest], n), do: closing_quote(rest, n + 1)
  defp closing_quote([], _n), do: :error

  # A tuple or list from its opening to its closing delimiter; a literal.
  defp node_range(ctx, {:__block__, _, [string]} = ast) when is_binary(string),
    do: string_range(ctx, ast)

  defp node_range(_ctx, {_, meta, _}) when is_list(meta) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column],
         closing when is_list(closing) <- meta[:closing] do
      {{line, column}, {closing[:line], closing[:column] + 1}}
    else
      _ -> nil
    end
  end

  defp node_range(_ctx, _ast), do: nil

  defp line_text(ctx, line) when line >= 1 and line <= tuple_size(ctx.lines),
    do: elem(ctx.lines, line - 1)

  defp line_text(_ctx, _line), do: nil

  # The value of a literal syntax tree, or :error for anything computed.
  defp literal({:__block__, _, [value]})
       when is_binary(value) or is_atom(value) or is_number(value),
       do: {:ok, value}

  defp literal({:__block__, _, [list]}) when is_list(list), do: literal_list(list)

  defp literal({:__block__, _, [{first, second}]}),
    do: literal_list([first, second], &List.to_tuple/1)

  defp literal({:{}, _, elements}), do: literal_list(elements, &List.to_tuple/1)

  defp literal({first, second}), do: literal_list([first, second], &List.to_tuple/1)
  defp literal(list) when is_list(list), do: literal_list(list)

  defp literal(_ast), do: :error

  defp literal_list(asts, wrap \\ & &1) do
    Enum.reduce_while(asts, {:ok, []}, fn ast, {:ok, acc} ->
      case literal(ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, wrap.(Enum.reverse(values))}
      :error -> :error
    end
  end

  defp location_line(location) when is_list(location), do: location[:line]
  defp location_line(line) when is_integer(line), do: line
  defp location_line(_location), do: nil

  defp text({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp text(text), do: to_string(text)
end
