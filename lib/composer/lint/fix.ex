defmodule Composer.Lint.Fix do
  @moduledoc """
  Applies the fixes of lint diagnostics (see `Composer.Lint.Diagnostic`)
  to the files they are in, for `mix composer.cookbook.lint --fix`.

  A fix replaces the source text at a range, so comments and layout
  survive. It is applied only while the range still holds the literal the
  diagnostic was about; fixes in one file are applied from the last range
  to the first, overlapping ones are skipped, and a file whose result no
  longer parses is left untouched.
  """

  alias Composer.Lint.Diagnostic

  @type result :: %{fixed: [Diagnostic.t()], skipped: [Diagnostic.t()]}

  @doc """
  Applies the fixes in `diagnostics`, writing each changed file. Returns
  the diagnostics whose fix was applied, and those with a fix that could
  not be.
  """
  @spec apply([Diagnostic.t()]) :: result()
  def apply(diagnostics) do
    diagnostics
    |> Enum.filter(& &1.fix)
    |> Enum.uniq_by(&{&1.file, &1.fix.range})
    |> Enum.group_by(& &1.file)
    |> Enum.reduce(%{fixed: [], skipped: []}, fn {file, fixes}, acc ->
      {fixed, skipped} = apply_file(file, fixes)
      %{fixed: acc.fixed ++ fixed, skipped: acc.skipped ++ skipped}
    end)
  end

  @doc """
  Applies `fixes` (diagnostics in one file) to `source`, returning the new
  source and the diagnostics applied and skipped.
  """
  @spec rewrite(String.t(), [Diagnostic.t()]) ::
          {String.t(), [Diagnostic.t()], [Diagnostic.t()]}
  def rewrite(source, fixes) do
    fixes
    |> Enum.sort_by(& &1.fix.range, :desc)
    |> Enum.reduce({source, [], [], nil}, fn d, {source, fixed, skipped, floor} ->
      %{range: {from, to} = range, expect: expect, text: text} = d.fix

      with true <- floor == nil or to <= floor,
           {:ok, before, slice, rest} <- split(source, range),
           true <- holds?(slice, expect) do
        {before <> text <> rest, [d | fixed], skipped, from}
      else
        _ -> {source, fixed, [d | skipped], floor}
      end
    end)
    |> then(fn {source, fixed, skipped, _floor} -> {source, fixed, Enum.reverse(skipped)} end)
  end

  defp apply_file(file, fixes) do
    with {:ok, source} <- File.read(file),
         {new, fixed, skipped} <- rewrite(source, fixes),
         {:ok, _quoted} <- Code.string_to_quoted(new, file: file) do
      if fixed != [], do: File.write!(file, new)
      {fixed, skipped}
    else
      _ -> {[], fixes}
    end
  end

  # The source before, at and after `range`, whose columns count
  # characters as Elixir's tokenizer does, on lines split at \n or \r\n.
  defp split(source, {{line, column}, {end_line, end_column}}) do
    lines = Regex.split(~r/(?<=\n)/, source)

    with {:ok, start} <- offset(lines, line, column),
         {:ok, stop} <- offset(lines, end_line, end_column),
         true <- start <= stop do
      {:ok, binary_part(source, 0, start), binary_part(source, start, stop - start),
       binary_part(source, stop, byte_size(source) - stop)}
    else
      _ -> :error
    end
  end

  # The byte offset of a 1-based line and character column.
  defp offset(lines, line, column) when line >= 1 and line <= length(lines) do
    {before, [text | _]} = Enum.split(lines, line - 1)
    head = text |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    if column - 1 <= String.length(head) do
      prefix = head |> String.graphemes() |> Enum.take(column - 1) |> Enum.join()
      {:ok, Enum.reduce(before, 0, &(byte_size(&1) + &2)) + byte_size(prefix)}
    else
      :error
    end
  end

  defp offset(_lines, _line, _column), do: :error

  # The text at the range must still be the literal the fix is for.
  defp holds?(slice, expect) do
    case Code.string_to_quoted(slice) do
      {:ok, quoted} -> literal(quoted) == {:ok, expect}
      _ -> false
    end
  end

  defp literal(quoted) do
    if Macro.quoted_literal?(quoted) do
      {value, _binding} = Code.eval_quoted(quoted)
      {:ok, value}
    else
      :error
    end
  end
end
