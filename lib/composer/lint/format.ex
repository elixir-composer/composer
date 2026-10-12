defmodule Composer.Lint.Format do
  @moduledoc """
  Renders `Composer.Lint.Diagnostic`s for `mix composer.cookbook.lint`.
  Every function is pure: it returns text and prints nothing.

    * `text/1` - the default: full messages, each after a
      `path:line:col:` location (relative to the current directory)
    * `compact/2` - one line per diagnostic,
      `file:line:col: severity: message [code]`, absolute paths, the
      message folded onto one line. The equivalent of Credo's `flycheck`
      and `oneline` formats, for editors.
    * `json/1` - an array of `Diagnostic.to_map/1`
    * `github/2` - GitHub Actions workflow commands (annotations)

  `compact/2` and `github/2` never print a line without a location: a
  diagnostic that has none is printed at `:1:1` of its first related
  file, or else of the `fallback` path.
  """

  alias Composer.Lint.Diagnostic

  @doc """
  The text format: `%{errors: [...], warnings: [...]}`, each a full
  message after its location.
  """
  @spec text([Diagnostic.t()]) :: %{errors: [String.t()], warnings: [String.t()]}
  def text(diagnostics) do
    {errors, warnings} = Enum.split_with(diagnostics, &Diagnostic.error?/1)
    %{errors: Enum.map(errors, &text_line/1), warnings: Enum.map(warnings, &text_line/1)}
  end

  defp text_line(%Diagnostic{file: nil} = d), do: d.message

  defp text_line(%Diagnostic{line: nil} = d),
    do: "#{Path.relative_to_cwd(d.file)}: #{d.message}"

  defp text_line(d), do: "#{Path.relative_to_cwd(d.file)}:#{d.line}:#{d.column}: #{d.message}"

  @doc "One line per diagnostic: `file:line:col: severity: message [code]`."
  @spec compact([Diagnostic.t()], Path.t() | nil) :: String.t()
  def compact(diagnostics, fallback \\ nil) do
    Enum.map_join(diagnostics, "\n", fn d ->
      {file, line, column} = position(d, fallback)
      "#{file}:#{line}:#{column}: #{d.severity}: #{fold(d.message)} [#{d.code}]"
    end)
  end

  @doc "The diagnostics as a pretty JSON array."
  @spec json([Diagnostic.t()]) :: String.t()
  def json(diagnostics) do
    diagnostics |> Enum.map(&Diagnostic.to_map/1) |> Jason.encode!(pretty: true)
  end

  @doc """
  GitHub Actions workflow commands: `::error file=…,line=…,col=…,…::message`.
  Paths are relative to the current directory, as GitHub matches them to
  the repository.
  """
  @spec github([Diagnostic.t()], Path.t() | nil) :: String.t()
  def github(diagnostics, fallback \\ nil) do
    Enum.map_join(diagnostics, "\n", fn d ->
      {file, line, column} = position(d, fallback)

      range =
        case Diagnostic.range(d) do
          {_start, {end_line, end_column}} -> [endLine: end_line, endColumn: end_column]
          nil -> []
        end

      properties =
        [file: Path.relative_to_cwd(file), line: line, col: column] ++
          range ++ [title: "composer lint [#{d.code}]"]

      props = Enum.map_join(properties, ",", fn {key, value} -> "#{key}=#{property(value)}" end)
      "::#{d.severity} #{props}::#{data(fold(d.message))}"
    end)
  end

  @doc """
  Folds a message onto one line: indented code blocks (lines indented by
  four spaces after a blank line) are dropped, and every run of
  whitespace becomes one space.
  """
  @spec fold(String.t()) :: String.t()
  def fold(message) do
    message
    |> String.split("\n")
    |> drop_blocks(nil, [])
    |> Enum.join(" ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp drop_blocks([], _previous, acc), do: Enum.reverse(acc)

  defp drop_blocks([line | rest], previous, acc) do
    if code?(line) and blank?(previous) do
      rest = Enum.drop_while(rest, &(code?(&1) or blank?(&1)))
      drop_blocks(rest, "", acc)
    else
      drop_blocks(rest, line, [line | acc])
    end
  end

  defp code?(line), do: String.starts_with?(line, "    ") and String.trim(line) != ""
  defp blank?(nil), do: true
  defp blank?(line), do: String.trim(line) == ""

  defp position(%Diagnostic{file: nil} = d, fallback) do
    file = Enum.find_value(d.related, & &1.file) || fallback || "."
    {Path.expand(file), 1, 1}
  end

  defp position(%Diagnostic{line: nil} = d, _fallback), do: {d.file, 1, 1}
  defp position(d, _fallback), do: {d.file, d.line, d.column}

  defp data(text) do
    text
    |> String.replace("%", "%25")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end

  defp property(value) do
    value
    |> to_string()
    |> data()
    |> String.replace(":", "%3A")
    |> String.replace(",", "%2C")
  end
end
