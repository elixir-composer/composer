defmodule Composer.Edit.Files.TextTest do
  use ExUnit.Case, async: true

  alias Composer.Edit.Files.Text

  test "lines/1 and unlines/2 keep the trailing newline, or its absence" do
    for content <- ["", "a\n", "a\nb\n", "a\nb", "a\n\n"] do
      {lines, trailing?} = Text.lines(content)
      assert Text.unlines(lines, trailing?) == content
    end

    assert Text.lines("a\nb") == {["a", "b"], false}
  end

  test "find_anchor/2 finds the first occurrence of a string or regex" do
    assert Text.find_anchor("one two two", "two") == {4, 3}
    assert Text.find_anchor("one two two", ~r/t\w+/) == {4, 3}
    assert Text.find_anchor("one", "two") == nil
    assert Text.line_index_of("a\nbb\nc", 3) == 1
  end

  describe "insert_lines/4" do
    test "appends, adding a newline to an unterminated last line" do
      assert Text.insert_lines("a\n", "x\n", :append, []) == {:ok, "a\nx\n"}
      assert Text.insert_lines("a", "x\n", :append, []) == {:ok, "a\nx\n"}
      assert Text.insert_lines("", "x\n", :append, []) == {:ok, "x\n"}
    end

    test "prepends, after a leading header when after: matches" do
      charset = ~r/\A@charset[^\n]*\n/

      assert Text.insert_lines("a\n", "x\n", :prepend, []) == {:ok, "x\na\n"}
      assert Text.insert_lines("a\n", "x\n", :prepend, after: charset) == {:ok, "x\na\n"}

      assert Text.insert_lines(~s(@charset "UTF-8";\na\n), "x\n", :prepend, after: charset) ==
               {:ok, ~s(@charset "UTF-8";\nx\na\n)}

      # A header pattern that stops mid-line still puts the line after it.
      assert Text.insert_lines("# head\na\n", "x\n", :prepend, after: ~r/\A#/) ==
               {:ok, "# head\nx\na\n"}
    end

    test "goes after or before the line holding the anchor" do
      assert Text.insert_lines("a\nbob\nc\n", "x\n", {:after, "o"}, []) == {:ok, "a\nbob\nx\nc\n"}

      assert Text.insert_lines("a\nbob\nc\n", "x\n", {:before, ~r/o/}, []) ==
               {:ok, "a\nx\nbob\nc\n"}

      assert Text.insert_lines("a\nc", "x\n", {:after, "c"}, []) == {:ok, "a\nc\nx\n"}
      assert Text.insert_lines("a\n", "x\n", {:after, "z"}, []) == :error
    end
  end

  test "splice/3 inserts right at the anchor, not on a line of its own" do
    assert Text.splice("one two", "!", {:after, "one"}) == {:ok, "one! two"}
    assert Text.splice("one two", "!", {:before, ~r/t/}) == {:ok, "one !two"}
    assert Text.splice("one", "!", :append) == {:ok, "one!"}
    assert Text.splice("one", "!", {:after, "z"}) == :error
  end

  describe "replace/4" do
    test "replaces every match, with back-references" do
      assert Text.replace("a1 b2 c3", ~r/(\w)(\d)/, "\\2\\1", nil) == "1a 2b 3c"
    end

    test "count: replaces only the first matches" do
      assert Text.replace("a a a", ~r/a/, "b", 1) == "b a a"
      assert Text.replace("a a a", ~r/a/, "b", 2) == "b b a"
      assert Text.replace("x1 x2 x3", ~r/x(\d)/, "y\\1", 2) == "y1 y2 x3"
    end

    test "count: doesn't re-match its own replacement" do
      assert Text.replace("a a", ~r/a/, "aa", 2) == "aa aa"
    end
  end
end
