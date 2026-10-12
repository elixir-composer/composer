defmodule Composer.LSP.PositionTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.Position

  # A combining é (e + U+0301), a precomposed é, an emoji outside the BMP
  # and a ZWJ family: 4 graphemes before the ref, each a different width.
  @combining "é"
  @line ~s(#{@combining}é😀👩‍👩‍👧 "core:x")
  # The ref's opening quote is grapheme 6.
  @column 6

  test "a column converts to each encoding's units" do
    family = "👩‍👩‍👧"

    assert Position.to_lsp(@line, @column, :utf8) ==
             byte_size(@combining <> "é😀" <> family <> " ")

    # e + U+0301 is 2 units, é 1, 😀 a surrogate pair, the family 8.
    assert Position.to_lsp(@line, @column, :utf16) == 2 + 1 + 2 + 8 + 1
    assert Position.to_lsp(@line, @column, :utf32) == 2 + 1 + 1 + 5 + 1
  end

  test "conversions round trip, in every encoding" do
    for encoding <- [:utf8, :utf16, :utf32], column <- 1..(String.length(@line) + 1) do
      character = Position.to_lsp(@line, column, encoding)
      assert Position.from_lsp(@line, character, encoding) == column
    end
  end

  test "a position inside a grapheme snaps to its start" do
    # Inside the surrogate pair of 😀 (grapheme 3, at UTF-16 unit 3).
    assert Position.from_lsp(@line, 4, :utf16) == 3
  end

  test "ASCII and past the end of a line" do
    assert Position.to_lsp("abc", 1, :utf16) == 0
    assert Position.to_lsp("abc", 6, :utf16) == 5
    assert Position.from_lsp("abc", 5, :utf8) == 6
  end

  test "a nil line passes the column through" do
    assert Position.to_lsp(nil, 7, :utf16) == 6
    assert Position.from_lsp(nil, 6, :utf32) == 7
  end

  test "negotiation prefers UTF-8, defaults to UTF-16" do
    assert Position.negotiate(["utf-16", "utf-8"]) == {:utf8, "utf-8"}
    assert Position.negotiate(["utf-32", "utf-16"]) == {:utf16, "utf-16"}
    assert Position.negotiate(["utf-32"]) == {:utf32, "utf-32"}
    assert Position.negotiate(nil) == {:utf16, "utf-16"}
  end
end
