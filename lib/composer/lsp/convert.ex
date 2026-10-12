defmodule Composer.LSP.Convert do
  @moduledoc """
  Maps Composer data to the Language Server Protocol's shapes, as plain
  maps with atom keys named like GenLSP's structure fields
  (`related_information`, `new_text`, ...). `Composer.LSP.Server` turns
  them into GenLSP structures; nothing here depends on GenLSP.

  Positions are converted with `Composer.LSP.Position`, which needs each
  line's text. A `line_fun` gives it: `line_fun.(path, line)` returns line
  `line` (1-based) of the file at `path`, or `nil`. `lines_for/1` builds
  one from the files on disk.
  """

  alias Composer.LSP.Position
  alias Composer.Lint.Diagnostic

  @type line_fun :: (Path.t(), pos_integer() -> String.t() | nil)
  @type lsp_position :: %{line: non_neg_integer(), character: non_neg_integer()}
  @type lsp_range :: %{start: lsp_position(), end: lsp_position()}

  @zero %{start: %{line: 0, character: 0}, end: %{line: 0, character: 0}}

  @doc """
  The LSP diagnostic of `d`, a diagnostic in file `d.file`. One with no
  position is placed at the start of the file. Its `data` carries the
  code and the suggestions, for code actions.
  """
  @spec diagnostic(Diagnostic.t(), Position.encoding(), line_fun()) :: map()
  def diagnostic(%Diagnostic{} = d, encoding, line_fun) do
    %{
      range: range(Diagnostic.range(d), encoding, &line_fun.(d.file, &1)),
      severity: severity(d.severity),
      code: Atom.to_string(d.code),
      source: "composer",
      message: d.message,
      related_information:
        for %{file: file, range: range, message: message} <- d.related, file != nil do
          %{
            location: %{
              uri: path_to_uri(file),
              range: range(range, encoding, &line_fun.(file, &1))
            },
            message: message
          }
        end,
      data: %{"code" => Atom.to_string(d.code), "suggestions" => d.suggestions}
    }
  end

  @doc "The LSP severity of a diagnostic severity."
  @spec severity(:error | :warning) :: 1 | 2
  def severity(:error), do: 1
  def severity(:warning), do: 2

  @doc """
  The LSP range of a Composer range (`nil` is the start of the file).
  `line_of.(line)` gives a line's text.
  """
  @spec range(Diagnostic.range() | nil, Position.encoding(), (pos_integer() -> String.t() | nil)) ::
          lsp_range()
  def range(nil, _encoding, _line_of), do: @zero

  def range({{line, column}, {end_line, end_column}}, encoding, line_of) do
    %{
      start: position(line, column, encoding, line_of),
      end: position(end_line, end_column, encoding, line_of)
    }
  end

  defp position(line, column, encoding, line_of) do
    %{line: max(line - 1, 0), character: Position.to_lsp(line_of.(line), column, encoding)}
  end

  @doc """
  A `line_fun` over the files at `paths`, each read once. A file that
  cannot be read has no lines.
  """
  @spec lines_for([Path.t()]) :: line_fun()
  def lines_for(paths) do
    files =
      Map.new(Enum.uniq(paths), fn path ->
        case File.read(path) do
          {:ok, source} -> {path, source |> String.split(~r/\r?\n/) |> List.to_tuple()}
          {:error, _} -> {path, {}}
        end
      end)

    fn path, line -> line_text(Map.get(files, path, {}), line) end
  end

  @doc "Line `line` (1-based) of a tuple of lines, or `nil`."
  @spec line_text(tuple(), integer()) :: String.t() | nil
  def line_text(lines, line) when line >= 1 and line <= tuple_size(lines),
    do: elem(lines, line - 1)

  def line_text(_lines, _line), do: nil

  @doc """
  The path of a `file:` URI, percent-decoded; `nil` for any other scheme.
  """
  @spec uri_to_path(String.t()) :: Path.t() | nil
  def uri_to_path("file://" <> rest) do
    # file:///path, or file://host/path with a host we ignore.
    path =
      case rest do
        "/" <> _ -> rest
        _ -> "/" <> (rest |> String.split("/", parts: 2) |> Enum.at(1, ""))
      end

    URI.decode(path)
  end

  def uri_to_path(_uri), do: nil

  @doc "The `file:` URI of an absolute path."
  @spec path_to_uri(Path.t()) :: String.t()
  def path_to_uri(path) do
    "file://" <> URI.encode(Path.expand(path), &(URI.char_unreserved?(&1) or &1 == ?/))
  end
end
