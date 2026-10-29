defmodule Composer.Edit.Files.Text do
  @moduledoc false

  # Pure string work for Composer.Edit.Files: splitting into lines, finding
  # anchors and inserting at a position. Offsets are bytes throughout
  # (`:binary` and `Regex.run(..., return: :index)`), never graphemes.

  @doc """
  Splits content into lines, and says whether it ended in a newline so
  `unlines/2` can write it back the same way.
  """
  def lines(""), do: {[], true}

  def lines(content) do
    parts = String.split(content, "\n")

    if List.last(parts) == "",
      do: {Enum.drop(parts, -1), true},
      else: {parts, false}
  end

  @doc "Joins lines split by `lines/1`."
  def unlines([], _trailing?), do: ""
  def unlines(lines, true), do: Enum.join(lines, "\n") <> "\n"
  def unlines(lines, false), do: Enum.join(lines, "\n")

  @doc "Returns `{start, length}` of the first occurrence of a string or regex anchor, or `nil`."
  def find_anchor(content, %Regex{} = anchor) do
    case Regex.run(anchor, content, return: :index) do
      [{start, length} | _] -> {start, length}
      nil -> nil
    end
  end

  def find_anchor(content, anchor) when is_binary(anchor) do
    case :binary.match(content, anchor) do
      {start, length} -> {start, length}
      :nomatch -> nil
    end
  end

  @doc "Returns the index of the line that contains byte `offset`."
  def line_index_of(content, offset) do
    content |> binary_part(0, offset) |> :binary.matches("\n") |> length()
  end

  @doc """
  Inserts whole lines (`chunk` ends in a newline) at a line position:
  `:append`, `:prepend` (after a leading `after:` match, if any), or
  `{:after, anchor}` / `{:before, anchor}` the line holding the anchor's
  first occurrence. Returns `{:ok, content}` or `:error` for a missing
  anchor.
  """
  def insert_lines(content, chunk, :append, _opts),
    do: {:ok, at(content, byte_size(content), chunk)}

  def insert_lines(content, chunk, :prepend, opts),
    do: {:ok, prepend_after(content, chunk, Keyword.get(opts, :after))}

  def insert_lines(content, chunk, {position, anchor}, _opts)
      when position in [:after, :before] do
    case find_anchor(content, anchor) do
      nil ->
        :error

      {start, _length} when position == :before ->
        {:ok, at(content, line_start(content, start), chunk)}

      {start, length} ->
        {:ok, at(content, line_end(content, start + max(length - 1, 0)), chunk)}
    end
  end

  @doc """
  Prepends `chunk`, or inserts it after the line that ends a match of
  `header` at the very start of the content (e.g. a CSS `@charset`).
  """
  def prepend_after(content, chunk, nil), do: chunk <> content

  def prepend_after(content, chunk, %Regex{} = header) do
    case Regex.run(header, content, return: :index) do
      [{0, length} | _] when length > 0 -> at(content, line_end(content, length - 1), chunk)
      _ -> chunk <> content
    end
  end

  @doc """
  The substring splice `Composer.Templates.insert/4` has always done:
  `content` goes right after or before the anchor, not on a line of its
  own. Returns `{:ok, content}` or `:error` for a missing anchor.
  """
  def splice(text, content, :append), do: {:ok, text <> content}
  def splice(text, content, :prepend), do: {:ok, content <> text}

  def splice(text, content, {position, anchor}) when position in [:after, :before] do
    case find_anchor(text, anchor) do
      nil ->
        :error

      {start, length} ->
        offset = if position == :after, do: start + length, else: start

        {:ok,
         binary_part(text, 0, offset) <>
           content <> binary_part(text, offset, byte_size(text) - offset)}
    end
  end

  @doc """
  Replaces matches of `pattern`: all of them when `count` is `nil`,
  otherwise the first `count`.
  """
  def replace(content, pattern, replacement, nil),
    do: Regex.replace(pattern, content, replacement)

  def replace(content, pattern, replacement, 1),
    do: Regex.replace(pattern, content, replacement, global: false)

  def replace(content, pattern, replacement, count) when is_integer(count) and count > 1,
    do: replace_n(content, pattern, replacement, count, 0)

  # Each pass rewrites only the matched slice, so back-references expand as
  # usual; a pattern relying on lookaround outside the match won't match the
  # slice alone and leaves it as is.
  defp replace_n(content, _pattern, _replacement, 0, _pos), do: content

  defp replace_n(content, pattern, replacement, count, pos) when pos <= byte_size(content) do
    case Regex.run(pattern, content, return: :index, offset: pos) do
      [{start, length} | _] ->
        slice = binary_part(content, start, length)
        new = Regex.replace(pattern, slice, replacement, global: false)
        rest = start + length

        content =
          binary_part(content, 0, start) <>
            new <> binary_part(content, rest, byte_size(content) - rest)

        # An empty match must still move on, or it would match again here.
        next = start + byte_size(new) + if(length == 0, do: 1, else: 0)
        replace_n(content, pattern, replacement, count - 1, next)

      nil ->
        content
    end
  end

  defp replace_n(content, _pattern, _replacement, _count, _pos), do: content

  # Inserts `chunk` at byte `offset`, adding a newline first when that would
  # otherwise join it to an unterminated last line.
  defp at(content, offset, chunk) do
    before = binary_part(content, 0, offset)
    rest = binary_part(content, offset, byte_size(content) - offset)
    separator = if before == "" or String.ends_with?(before, "\n"), do: "", else: "\n"
    before <> separator <> chunk <> rest
  end

  defp line_start(content, offset) do
    case content |> binary_part(0, offset) |> :binary.matches("\n") do
      [] -> 0
      newlines -> newlines |> List.last() |> elem(0) |> Kernel.+(1)
    end
  end

  defp line_end(content, offset) do
    case :binary.match(content, "\n", scope: {offset, byte_size(content) - offset}) do
      {newline, 1} -> newline + 1
      :nomatch -> byte_size(content)
    end
  end
end
