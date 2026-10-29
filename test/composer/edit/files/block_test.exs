defmodule Composer.Edit.Files.BlockTest do
  use ExUnit.Case, async: true

  alias Composer.Edit.Files.Block

  test "comment_for/2 picks the syntax by extension or file name" do
    assert Block.comment_for("assets/app.css", []) == {"/*", "*/"}
    assert Block.comment_for("assets/app.ts", []) == {"/*", "*/"}
    assert Block.comment_for("lib/app.ex", []) == {"#", ""}
    assert Block.comment_for(".gitignore", []) == {"#", ""}
    assert Block.comment_for("lib/app_web/home.html.heex", []) == {"<!--", "-->"}
  end

  test "comment_for/2 takes comment: over the extension, and raises for an unknown one" do
    assert Block.comment_for("app.css", comment: {"--", ""}) == {"--", ""}
    assert Block.comment_for("query.sql", comment: {"--", ""}) == {"--", ""}

    assert_raise ArgumentError, ~r/no comment syntax is known for query.sql/, fn ->
      Block.comment_for("query.sql", [])
    end
  end

  test "wrap/3 puts the block between markers, ending in a newline" do
    assert Block.wrap("a", {"/*", "*/"}, "x") ==
             "/* composer:begin x */\na\n/* composer:end x */\n"

    assert Block.wrap("a\n", {"#", ""}, "x") == "# composer:begin x\na\n# composer:end x\n"
  end

  test "find/3 returns the marked region, tolerating whitespace in the markers" do
    content = "top\n  /*composer:begin x   */\na\n/* composer:end x */\nbottom\n"
    {start, stop} = Block.find(content, {"/*", "*/"}, "x")

    assert binary_part(content, 0, start) == "top\n"
    assert binary_part(content, stop, byte_size(content) - stop) == "bottom\n"
  end

  test "find/3 tells a missing block from an unclosed one, and ids apart" do
    content = "/* composer:begin x */\na\n"

    assert Block.find(content, {"/*", "*/"}, "x") == {:unclosed, 0}
    assert Block.find(content, {"/*", "*/"}, "y") == nil

    assert Block.find("/* composer:begin xy */\n/* composer:end xy */\n", {"/*", "*/"}, "x") ==
             nil
  end
end
