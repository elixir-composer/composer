defmodule Composer.LSP.Cursor do
  @moduledoc """
  What is under the cursor in a recipe group buffer.

  When the buffer parses, `Composer.Recipe.Locator` answers. Otherwise a
  line scan finds the string literal enclosing the cursor: a `{:use, ...}`
  target when `{:use,` precedes it, a reference otherwise. The scan knows
  string literals, the `{:use,` prefix and keys (`steps:`) and nothing
  else; references are parsed by `Composer.Ref`.

  Lines and columns are 1-based, columns in graphemes, as the locator's.
  """

  alias Composer.Recipe.Locator

  @type range :: Composer.Lint.Diagnostic.range()

  @type t :: %{
          kind: :ref | :use | :alias | :key | :recipe,
          recipe: String.t() | nil,
          value: term(),
          range: range(),
          aliases: %{String.t() => String.t()}
        }

  @type literal :: %{
          value: String.t(),
          start: pos_integer(),
          end: pos_integer() | nil
        }

  # Keys of a recipe; any other `name: [` is a recipe's name key.
  @recipe_keys ~w(shortdoc doc flags aliases steps)

  @doc "What is at `line`, `column` of `text`, or `nil`."
  @spec at(String.t(), Path.t(), pos_integer(), pos_integer()) :: t() | nil
  def at(text, path, line, column) do
    case Locator.index(text, path) do
      {:ok, index} -> located(index, line, column)
      {:error, _} -> scanned(text, line, column)
    end
  end

  defp located(index, line, column) do
    case Locator.at(index, line, column) do
      {kind, recipe, value, range} ->
        targets = Locator.recipe(index, recipe).alias_targets
        aliases = Map.new(targets, fn {name, target} -> {Atom.to_string(name), target} end)
        %{kind: kind, recipe: recipe, value: value, range: range, aliases: aliases}

      nil ->
        nil
    end
  end

  defp scanned(text, line, column) do
    lines = String.split(text, ~r/\r?\n/)
    line_text = Enum.at(lines, line - 1)

    case line_text && literal_at(line_text, column) do
      %{end: end_column} = literal when end_column != nil ->
        before = line_text |> String.graphemes() |> Enum.take(literal.start - 1) |> Enum.join()

        %{
          kind: if(use_prefix?(before), do: :use, else: :ref),
          recipe: recipe_before(lines, line),
          value: literal.value,
          range: {{line, literal.start}, {line, end_column}},
          aliases: scan_aliases(text, line)
        }

      _ ->
        nil
    end
  end

  @doc """
  The string literal on `line_text` enclosing `column`: its value, the
  column of its opening quote and the column after its closing quote
  (`nil` when the line ends inside it). The cursor is inside from the
  opening quote up to the closing one.
  """
  @spec literal_at(String.t(), pos_integer()) :: literal() | nil
  def literal_at(line_text, column) do
    Enum.find(literals(line_text), fn literal ->
      column >= literal.start and (literal.end == nil or column < literal.end)
    end)
  end

  @doc "Every string literal on `line_text`, in order (see `literal_at/2`)."
  @spec literals(String.t()) :: [literal()]
  def literals(line_text), do: scan(String.graphemes(line_text), 1, nil, [])

  # Outside a string: `#` starts a comment, `"` a literal.
  defp scan([], _column, nil, acc), do: Enum.reverse(acc)

  defp scan([], _column, {start, value}, acc),
    do: Enum.reverse([%{value: value, start: start, end: nil} | acc])

  defp scan(["#" | _rest], _column, nil, acc), do: Enum.reverse(acc)
  defp scan(["?", _char | rest], column, nil, acc), do: scan(rest, column + 2, nil, acc)
  defp scan(["\"" | rest], column, nil, acc), do: scan(rest, column + 1, {column, ""}, acc)
  defp scan([_ | rest], column, nil, acc), do: scan(rest, column + 1, nil, acc)

  defp scan(["\\", char | rest], column, {start, value}, acc),
    do: scan(rest, column + 2, {start, value <> char}, acc)

  defp scan(["\"" | rest], column, {start, value}, acc),
    do: scan(rest, column + 1, nil, [%{value: value, start: start, end: column + 1} | acc])

  defp scan([char | rest], column, {start, value}, acc),
    do: scan(rest, column + 1, {start, value <> char}, acc)

  defp use_prefix?(before), do: Regex.match?(~r/\{\s*:use\s*,\s*\z/, before)

  @doc """
  The completion context at `line`, `column` of `text`, by line scan:
  `{:steps | :use, prefix, replace_range}` inside a string literal of a
  `steps:` list (`:use` after `{:use,`), else `nil`. `replace_range`
  covers the literal's contents.
  """
  @spec context(String.t(), pos_integer(), pos_integer()) ::
          {:steps | :use, String.t(), range()} | nil
  def context(text, line, column) do
    lines = String.split(text, ~r/\r?\n/)
    line_text = Enum.at(lines, line - 1)

    with true <- is_binary(line_text),
         %{start: start} = literal when start < column <- literal_at(line_text, column) do
      graphemes = String.graphemes(line_text)
      before = graphemes |> Enum.take(start - 1) |> Enum.join()
      prefix = graphemes |> Enum.slice(start, column - start - 1) |> Enum.join()
      stop = if literal.end, do: literal.end - 1, else: length(graphemes) + 1
      range = {{line, start + 1}, {line, stop}}

      cond do
        use_prefix?(before) -> {:use, prefix, range}
        in_steps?(lines, line, before) -> {:steps, prefix, range}
        true -> nil
      end
    else
      _ -> nil
    end
  end

  # True when the literal belongs to a `steps:` list: the nearest key
  # before it on its line, or else the key starting the nearest earlier
  # line indented less than this one, is `steps:`.
  defp in_steps?(lines, line, before) do
    case last_key(code(before)) do
      nil ->
        indent = indent(Enum.at(lines, line - 1))

        lines
        |> Enum.take(line - 1)
        |> Enum.reverse()
        |> Enum.find_value(fn text ->
          code = code(text)

          case Regex.run(~r/\A(\s*)([a-z_][a-z0-9_]*):\s/, code <> " ") do
            [_, spaces, key] -> if String.length(spaces) < indent, do: {:key, key}
            nil -> if last_key(code) == "steps" and indent(text) < indent, do: {:key, "steps"}
          end
        end)
        |> Kernel.==({:key, "steps"})

      key ->
        key == "steps"
    end
  end

  # The text with its string literals and comment removed.
  defp code(text) do
    graphemes = String.graphemes(text)

    {kept, column} =
      Enum.reduce(literals(text), {[], 1}, fn literal, {kept, column} ->
        piece = Enum.slice(graphemes, column - 1, literal.start - column)
        {[kept, piece, ~s("")], literal.end || length(graphemes) + 1}
      end)

    [kept, Enum.drop(graphemes, column - 1)]
    |> IO.iodata_to_binary()
    |> String.split("#", parts: 2)
    |> hd()
  end

  defp last_key(code) do
    case Regex.scan(~r/([a-z_][a-z0-9_]*):(?=\s)/, code <> " ", capture: :all_but_first) do
      [] -> nil
      keys -> keys |> List.last() |> hd()
    end
  end

  defp indent(text), do: String.length(text) - String.length(String.trim_leading(text))

  # The nearest recipe name key above `line`, best effort.
  defp recipe_before(lines, line) do
    lines
    |> Enum.take(line)
    |> Enum.reverse()
    |> Enum.find_value(fn text ->
      case Regex.run(~r/\A\s*([a-z0-9_]+):\s*\[/, code(text)) do
        [_, name] when name not in @recipe_keys -> name
        _ -> nil
      end
    end)
  end

  @doc """
  The cookbook aliases written in `text`, read by scanning `aliases:`
  lists and the top-level bindings `aliases:` names, the nearest one
  starting on or above `line` first. Best effort, for a buffer that does not parse.
  """
  @spec scan_aliases(String.t(), pos_integer()) :: %{String.t() => String.t()}
  def scan_aliases(text, line) do
    offset =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.take(line)
      |> Enum.map(&(byte_size(&1) + 1))
      |> Enum.sum()

    # `aliases: [...]`, and each `name = [...]` that an `aliases: name` names.
    bound =
      ~r/aliases:\s*([a-z_][a-z0-9_]*)/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.flat_map(fn name ->
        Regex.scan(~r/(?:^|\n)\s*#{name}\s*=\s*\[([^\]]*)\]/, text, return: :index, capture: :all)
      end)

    ~r/aliases:\s*\[([^\]]*)\]/
    |> Regex.scan(text, return: :index, capture: :all)
    |> Kernel.++(bound)
    |> Enum.sort_by(fn [{start, _}, _] ->
      if start <= offset, do: {0, -start}, else: {1, start}
    end)
    |> Enum.reduce(%{}, fn [_, {start, length}], acc ->
      ~r/([a-z0-9_]+):\s*"([a-z0-9_]+)"/
      |> Regex.scan(binary_part(text, start, length), capture: :all_but_first)
      |> Enum.reduce(acc, fn [name, target], acc -> Map.put_new(acc, name, target) end)
    end)
  end
end
