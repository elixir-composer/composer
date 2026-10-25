defmodule Composer.LSP.Complete do
  @moduledoc """
  Completion items for a context from `Composer.LSP.Cursor.context/3`,
  one segment at a time, as the shell completes, from the prefix typed so
  far:

    * empty or a name: cookbook and alias names (`cb_std/`, `cb_std:`,
      `lab/`, `lab:`), `./`, `../`, `/` and `:` (the buffer's cookbook),
      and `hex:`
    * `./`, `../`, `../../`: the recipes and directories relative to the
      buffer's chapter
    * `/`, `:`: the next segment in the buffer's cookbook
    * `cb_std/`, `cb_std:`, `lab:`: the next segment in that cookbook (an
      alias is completed as written)

  In a step's `requires:` list only step addresses are offered. Items are
  built from the entries of the completion index (`Composer.Index`), as
  `%{label, kind, detail, range}` where `kind` is `:step`, `:recipe`,
  `:folder` (a chapter, directory or group, completed further),
  `:cookbook`, `:alias` or `:keyword` (`./`, `../`, `/`, `:`, `hex:`), and
  `range` is the literal's contents, which the item replaces.
  """

  @type item :: %{
          label: String.t(),
          kind: :step | :recipe | :folder | :cookbook | :alias | :keyword,
          detail: String.t(),
          range: Composer.Lint.Diagnostic.range()
        }

  @type buffer :: %{cookbook: String.t() | nil, chapter: String.t() | nil}

  @doc """
  The items for `context`, from `entries` (`{kind, id, text}`), the
  recipe's `aliases` (`%{"lab" => "cc_lab"}`) and the buffer's cookbook
  and chapter.
  """
  @spec items(
          {:steps | :requires, String.t(), Composer.Lint.Diagnostic.range()} | nil,
          list(),
          map(),
          map()
        ) :: [item()]
  def items(context, entries, aliases, buffer \\ %{cookbook: nil, chapter: nil})
  def items(nil, _entries, _aliases, _buffer), do: []

  def items({kind, prefix, range}, entries, aliases, buffer) do
    buffer = Map.merge(%{cookbook: nil, chapter: nil}, buffer)

    prefix
    |> candidates(entries, aliases, buffer, kind == :requires)
    |> Enum.filter(fn {label, _kind, _detail} -> String.starts_with?(label, prefix) end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {label, type, detail} ->
      %{label: label, kind: type, detail: detail || "", range: range}
    end)
  end

  defp candidates(prefix, entries, aliases, buffer, steps_only?) do
    cond do
      String.starts_with?(prefix, ".") ->
        if steps_only?, do: [], else: relative(prefix, entries, buffer)

      String.starts_with?(prefix, "/") ->
        if steps_only? or buffer.cookbook == nil,
          do: [],
          else: segments(prefix, "/", "", buffer.cookbook, entries)

      String.starts_with?(prefix, ":") ->
        if buffer.cookbook == nil,
          do: [],
          else: segments(prefix, ":", "", buffer.cookbook, entries)

      String.contains?(prefix, ["/", ":"]) ->
        qualified(prefix, entries, aliases, steps_only?)

      true ->
        starters(entries, aliases, buffer, steps_only?)
    end
  end

  # Where an address can start.
  defp starters(entries, aliases, buffer, steps_only?) do
    seps = if steps_only?, do: [":"], else: ["/", ":"]

    cookbooks =
      for {"cookbook", name, text} <- entries, sep <- seps, do: {name <> sep, :cookbook, text}

    aliased =
      for {name, target} <- Enum.sort(aliases),
          sep <- seps,
          do: {name <> sep, :alias, "alias for #{target}"}

    own =
      case buffer.cookbook do
        nil -> []
        own when steps_only? -> [{":", :keyword, "a step of #{own}"}]
        own -> [{"/", :keyword, "a recipe of #{own}"}, {":", :keyword, "a step of #{own}"}]
      end

    relative = if buffer.chapter && not steps_only?, do: relative_starters(), else: []

    relative ++ own ++ cookbooks ++ aliased ++ [{"hex:", :keyword, "a Hex package"}]
  end

  defp relative_starters,
    do: [{"./", :keyword, "a recipe in this chapter"}, {"../", :keyword, "a recipe above it"}]

  defp qualified(prefix, entries, aliases, steps_only?) do
    [book] = Regex.run(~r/\A[^\/:]*/, prefix)
    rest = String.slice(prefix, String.length(book)..-1//1)
    sep = String.first(rest)

    if steps_only? and sep == "/",
      do: [],
      else: segments(rest, sep, book, Map.get(aliases, book, book), entries)
  end

  # The next segment of the addresses in cookbook `target` that start with
  # `rest` (which begins with `sep`), written with `book` for the cookbook.
  # A chapter, directory or group comes after the recipes and steps.
  defp segments(rest, sep, book, target, entries) do
    kinds = if sep == "/", do: ["recipe", "chapter", "dir"], else: ["step", "group"]
    item = target <> rest
    # The item up to and including its last separator.
    stem = String.replace(item, ~r/[^\/:]*\z/, "")
    written = book <> String.slice(stem, String.length(target)..-1//1)

    for {kind, id, text} <- entries,
        kind in kinds,
        String.starts_with?(id, item),
        remainder = String.slice(id, String.length(stem)..-1//1),
        remainder != "" do
      case String.split(remainder, sep, parts: 2) do
        [segment, _more] ->
          {written <> segment <> sep, :folder, if(kind in ["chapter", "dir", "group"], do: text)}

        [segment] ->
          {written <> segment, if(kind == "step", do: :step, else: :recipe), text}
      end
    end
    |> Enum.sort_by(fn {label, kind, detail} -> {kind == :folder, label, detail == nil} end)
  end

  # "./x", "../x", "../../x": the recipes of the buffer's cookbook from its
  # chapter, `up` levels up.
  defp relative(prefix, entries, %{cookbook: own, chapter: chapter})
       when is_binary(own) and is_binary(chapter) do
    case Regex.run(~r/\A((?:\.\.\/)+|\.\/)(.*)\z/, prefix) do
      [_, dots, rest] ->
        up = if dots == "./", do: 0, else: div(String.length(dots), 3)
        base = String.split(chapter, "/")

        if up > length(base) do
          []
        else
          target = Enum.join([own | Enum.drop(base, -up)], "/")

          for {label, kind, text} <- segments("/" <> rest, "/", "", target, entries),
              do: {dots <> String.trim_leading(label, "/"), kind, text}
        end

      nil ->
        relative_starters()
    end
  end

  defp relative(_prefix, _entries, _buffer), do: []
end
