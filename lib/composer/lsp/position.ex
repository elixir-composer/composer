defmodule Composer.LSP.Position do
  @moduledoc """
  Converts columns between Composer and the Language Server Protocol.

  Composer's columns (`Composer.Lint.Diagnostic`, `Composer.Recipe.Locator`)
  are 1-based and count grapheme clusters, as Elixir's tokenizer does. An
  LSP `character` is 0-based and counts code units of the negotiated
  position encoding: UTF-16 (the protocol's default), UTF-8 bytes or
  UTF-32 codepoints. Lines differ only by one (1-based against 0-based).

  Conversion needs the line's text. With no text (a line past the end of
  the file), a column passes through, shifted by one.
  """

  @type encoding :: :utf8 | :utf16 | :utf32

  # Our preference: UTF-8 is cheapest, and recipe files are ASCII almost
  # everywhere. UTF-16 is the protocol's default and always supported.
  @preference [utf8: "utf-8", utf16: "utf-16", utf32: "utf-32"]

  @doc """
  Picks the position encoding from the client's `positionEncodings`
  (`nil` when it sent none), as `{encoding, wire_name}`.
  """
  @spec negotiate([String.t()] | nil) :: {encoding(), String.t()}
  def negotiate(offered) do
    offered = List.wrap(offered)

    Enum.find(@preference, {:utf16, "utf-16"}, fn {_encoding, wire} -> wire in offered end)
  end

  @doc """
  The LSP `character` of Composer `column` (1-based, in graphemes) on a
  line of text `line_text`.
  """
  @spec to_lsp(String.t() | nil, pos_integer(), encoding()) :: non_neg_integer()
  def to_lsp(nil, column, _encoding), do: max(column - 1, 0)

  def to_lsp(line_text, column, encoding) do
    graphemes = String.graphemes(line_text)
    wanted = max(column - 1, 0)
    {prefix, _rest} = Enum.split(graphemes, wanted)
    past_end = wanted - length(prefix)

    units(Enum.join(prefix), encoding) + past_end
  end

  @doc """
  The Composer column (1-based, in graphemes) of LSP `character` on a line
  of text `line_text`. A position inside a grapheme snaps to its start.
  """
  @spec from_lsp(String.t() | nil, non_neg_integer(), encoding()) :: pos_integer()
  def from_lsp(nil, character, _encoding), do: character + 1

  def from_lsp(line_text, character, encoding) do
    line_text
    |> String.graphemes()
    |> Enum.reduce_while({1, 0}, fn grapheme, {column, units} ->
      size = units(grapheme, encoding)

      if units + size > character,
        do: {:halt, {:found, column}},
        else: {:cont, {column + 1, units + size}}
    end)
    |> case do
      {:found, column} -> column
      {column, units} -> column + (character - units)
    end
  end

  @doc "The length of `string` in code units of `encoding`."
  @spec units(String.t(), encoding()) :: non_neg_integer()
  def units(string, :utf8), do: byte_size(string)
  def units(string, :utf32), do: string |> String.to_charlist() |> length()

  def units(string, :utf16),
    do: div(byte_size(:unicode.characters_to_binary(string, :utf8, :utf16)), 2)
end
