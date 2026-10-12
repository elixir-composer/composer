defmodule Composer.Lint.Diagnostic do
  @moduledoc """
  One problem found by `Composer.Lint`: what is wrong, how bad it is, and
  where.

  The shape follows an LSP `Diagnostic`, so an editor integration only has
  to translate it:

    * `severity` - `:error` or `:warning`
    * `code` - the reason's tag (`:typo`, `:missing_step`, `:cycle`,
      `:unused_alias`, ...). Codes are public and stable; they are listed
      in the lint guide.
    * `file` - an absolute path, or `nil` when nothing can be located
    * `line`, `column` - where the problem starts; `end_line`,
      `end_column` - where it ends (exclusive). `nil` when only the file
      is known.
    * `message` - the full text of `Composer.Error.message/1`
    * `reason` - the raw reason tuple
    * `suggestions` - replacement references, from the `typo`,
      `missing_step` and `missing_recipe` reasons
    * `related` - other places involved, as `%{file, range, message}`
      (the other origin of a `conflicting_install`, each hop of a `cycle`,
      the first key of a `duplicate_recipe`, ...)

  ## Positions

  Lines and columns are 1-based. Columns count characters as Elixir's
  tokenizer does (grapheme clusters), not bytes or UTF-16 code units. When
  `column` is set, `end_line` and `end_column` are set too. A range is
  `{{line, column}, {end_line, end_column}}`.
  """

  alias Composer.Error

  defstruct [
    :severity,
    :code,
    :file,
    :line,
    :column,
    :end_line,
    :end_column,
    :message,
    :reason,
    suggestions: [],
    related: []
  ]

  @type position :: {pos_integer(), pos_integer()}
  @type range :: {position(), position()}
  @type related :: %{file: Path.t() | nil, range: range() | nil, message: String.t()}

  @type t :: %__MODULE__{
          severity: :error | :warning,
          code: atom(),
          file: Path.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          message: String.t(),
          reason: term(),
          suggestions: [String.t()],
          related: [related()]
        }

  @doc "An unlocated diagnostic for `reason`."
  @spec new(:error | :warning, term()) :: t()
  def new(severity, reason) when severity in [:error, :warning] do
    %__MODULE__{
      severity: severity,
      code: code(reason),
      message: reason |> Error.message() |> String.trim(),
      reason: reason,
      suggestions: suggestions(reason)
    }
  end

  @doc """
  Places a diagnostic: in `file`, over `range` (or at no particular
  position when `range` is `nil`), with `related` locations.
  """
  @spec locate(t(), Path.t() | nil, range() | nil, [related()]) :: t()
  def locate(diagnostic, file, range, related \\ [])

  def locate(%__MODULE__{} = diagnostic, nil, _range, related),
    do: %{diagnostic | related: related}

  def locate(%__MODULE__{} = diagnostic, file, nil, related),
    do: %{diagnostic | file: Path.expand(file), related: related}

  def locate(%__MODULE__{} = diagnostic, file, {{line, column}, {end_line, end_column}}, related) do
    %{
      diagnostic
      | file: Path.expand(file),
        line: line,
        column: column,
        end_line: end_line,
        end_column: end_column,
        related: related
    }
  end

  @doc "The diagnostic's range, or `nil`."
  @spec range(t()) :: range() | nil
  def range(%__MODULE__{column: nil}), do: nil

  def range(%__MODULE__{} = d), do: {{d.line, d.column}, {d.end_line, d.end_column}}

  @doc "True for an error."
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{severity: severity}), do: severity == :error

  @doc "The diagnostic code of a reason: its tag."
  @spec code(term()) :: atom()
  def code(reason) when is_tuple(reason), do: elem(reason, 0)
  def code(reason) when is_atom(reason), do: reason

  @doc """
  The suggested replacements carried by a reason (`typo`, `missing_step`,
  `missing_recipe`, also behind a cookbook alias).
  """
  @spec suggestions(term()) :: [String.t()]
  def suggestions({:via_alias, _written, _name, _target, reason}), do: suggestions(reason)
  def suggestions({tag, _ref, _origin, list}) when tag in [:typo, :missing_step], do: list
  def suggestions({:missing_recipe, _ref, _origin, list}), do: list
  def suggestions(_reason), do: []

  @doc """
  The diagnostic as JSON-ready data. `reason` is left out: tuples do not
  encode.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d) do
    %{
      "severity" => Atom.to_string(d.severity),
      "code" => Atom.to_string(d.code),
      "file" => d.file,
      "line" => d.line,
      "column" => d.column,
      "end_line" => d.end_line,
      "end_column" => d.end_column,
      "message" => d.message,
      "suggestions" => d.suggestions,
      "related" => Enum.map(d.related, &related_map/1)
    }
  end

  defp related_map(%{file: file, range: range, message: message}) do
    {{line, column}, {end_line, end_column}} = range || {{nil, nil}, {nil, nil}}

    %{
      "file" => file,
      "line" => line,
      "column" => column,
      "end_line" => end_line,
      "end_column" => end_column,
      "message" => message
    }
  end
end
