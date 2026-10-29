defmodule Composer.Edit.FilesTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Composer.Edit.Files
  alias Composer.Templates

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp project(path, content), do: test_project(files: %{path => content})

  # Applies the first run, then runs `edit` again: it must change nothing
  # and warn about nothing.
  defp assert_idempotent(igniter, path, edit) do
    assert igniter.warnings == []
    second = igniter |> apply_igniter!() |> edit.()

    assert_unchanged(second, path)
    assert second.warnings == []
    second
  end

  describe "ensure_line/4" do
    test "adds a missing line at :append, :prepend, or after or before an anchor" do
      igniter = project("notes.txt", "one\ntwo\n")

      assert igniter |> Files.ensure_line("notes.txt", "end") |> content("notes.txt") ==
               "one\ntwo\nend\n"

      assert igniter
             |> Files.ensure_line("notes.txt", "top", at: :prepend)
             |> content("notes.txt") ==
               "top\none\ntwo\n"

      assert igniter
             |> Files.ensure_line("notes.txt", "1.5", at: {:after, "on"})
             |> content("notes.txt") == "one\n1.5\ntwo\n"

      assert igniter
             |> Files.ensure_line("notes.txt", "1.5", at: {:before, ~r/tw/})
             |> content("notes.txt") == "one\n1.5\ntwo\n"
    end

    test ":prepend with after: lands after a leading @charset" do
      edit =
        &Files.ensure_line(&1, "app.css", ~s(@import "tailwindcss";),
          at: :prepend,
          after: ~r/\A@charset[^\n]*\n/
        )

      igniter = project("app.css", ~s(@charset "UTF-8";\nbody {}\n)) |> edit.()

      assert content(igniter, "app.css") ==
               ~s(@charset "UTF-8";\n@import "tailwindcss";\nbody {}\n)

      assert_idempotent(igniter, "app.css", edit)
    end

    test "match: replaces a differing line in place, once" do
      edit =
        &Files.ensure_line(&1, "app.css", ~s(@import "tailwindcss";),
          match: ~r/^@import\s+["']tailwindcss["']/,
          at: :prepend
        )

      igniter = project("app.css", "body {}\n@import 'tailwindcss'\n") |> edit.()

      assert content(igniter, "app.css") == ~s(body {}\n@import "tailwindcss";\n)
      assert_idempotent(igniter, "app.css", edit)
    end

    test "state: :absent removes every match, silently when there is none" do
      igniter = project("app.ts", "import './a.css'\n\nimport './a.css'\nlet x\n")

      removed =
        Files.ensure_line(igniter, "app.ts", nil, match: ~r/a\.css/, state: :absent)

      assert content(removed, "app.ts") == "\nlet x\n"

      collapsed =
        Files.ensure_line(igniter, "app.ts", nil,
          match: ~r/a\.css/,
          state: :absent,
          collapse_blank: true
        )

      assert content(collapsed, "app.ts") == "let x\n"

      none = Files.ensure_line(igniter, "app.ts", "nothing", state: :absent)
      assert_unchanged(none, "app.ts")
      assert none.warnings == []

      missing = Files.ensure_line(test_project(), "gone.ts", "x", state: :absent)
      assert missing.warnings == []
      refute_creates(missing, "gone.ts")
    end

    test "create: true creates a missing file holding the line" do
      edit = &Files.ensure_line(&1, "new.css", "@import \"x\";", at: :prepend, create: true)
      igniter = edit.(test_project())

      assert_creates(igniter, "new.css", "@import \"x\";\n")
      assert_idempotent(igniter, "new.css", edit)
    end

    test "a missing file or anchor warns with the suffix and changes nothing" do
      missing = Files.ensure_line(test_project(), "gone.txt", "x")

      assert missing.warnings == [
               "gone.txt not found (Composer.Edit.Files.ensure_line was skipped)"
             ]

      refute_creates(missing, "gone.txt")

      no_anchor =
        Files.ensure_line(project("notes.txt", "one\n"), "notes.txt", "x", at: {:after, "z"})

      assert_unchanged(no_anchor, "notes.txt")

      assert no_anchor.warnings == [
               ~s(could not find "z" in notes.txt, so nothing was inserted after it ) <>
                 "(Composer.Edit.Files.ensure_line was skipped)"
             ]
    end

    test "warning: rewords the message and keeps the suffix" do
      igniter = Files.ensure_line(test_project(), "gone.txt", "x", warning: "no notes yet")

      assert igniter.warnings == ["no notes yet (Composer.Edit.Files.ensure_line was skipped)"]
    end

    test "a second run is empty" do
      edit = &Files.ensure_line(&1, "notes.txt", "1.5", at: {:after, "one"})
      igniter = project("notes.txt", "one\ntwo\n") |> edit.()

      assert content(igniter, "notes.txt") == "one\n1.5\ntwo\n"
      assert_idempotent(igniter, "notes.txt", edit)
    end

    test "rejects a typo in the options and a missing line" do
      assert_raise ArgumentError, fn ->
        Files.ensure_line(test_project(), "a", "x", math: ~r/x/)
      end

      assert_raise ArgumentError, fn -> Files.ensure_line(test_project(), "a", nil) end
    end
  end

  describe "ensure_block/4" do
    @css "body {}\n"

    test "inserts the block with CSS markers, and a second run is empty" do
      edit = &Files.ensure_block(&1, "app.css", "@plugin \"daisyui\";", id: "daisyui")
      igniter = project("app.css", @css) |> edit.()

      assert content(igniter, "app.css") == """
             body {}
             /* composer:begin daisyui */
             @plugin "daisyui";
             /* composer:end daisyui */
             """

      assert_idempotent(igniter, "app.css", edit)
    end

    test "replaces the text between markers, whether changed by the step or by hand" do
      marked = """
      body {}
      /* composer:begin daisyui */
      @plugin "old";
      /* composer:end daisyui */
      tail {}
      """

      igniter =
        project("app.css", marked)
        |> Files.ensure_block("app.css", "@plugin \"daisyui\";\n", id: "daisyui")

      assert content(igniter, "app.css") == """
             body {}
             /* composer:begin daisyui */
             @plugin "daisyui";
             /* composer:end daisyui */
             tail {}
             """
    end

    test "state: :absent removes the block and its markers, silently when missing" do
      marked = "a {}\n/* composer:begin x */\nb {}\n/* composer:end x */\nc {}\n"

      removed =
        project("app.css", marked) |> Files.ensure_block("app.css", "", id: "x", state: :absent)

      assert content(removed, "app.css") == "a {}\nc {}\n"

      none =
        project("app.css", @css) |> Files.ensure_block("app.css", "", id: "x", state: :absent)

      assert_unchanged(none, "app.css")
      assert none.warnings == []
    end

    test "two ids in one file stay independent" do
      igniter =
        project("app.css", @css)
        |> Files.ensure_block("app.css", "one {}", id: "one")
        |> Files.ensure_block("app.css", "two {}", id: "two", at: {:before, "body"})
        |> Files.ensure_block("app.css", "one {} /* v2 */", id: "one")

      assert content(igniter, "app.css") == """
             /* composer:begin two */
             two {}
             /* composer:end two */
             body {}
             /* composer:begin one */
             one {} /* v2 */
             /* composer:end one */
             """
    end

    test "comment syntax follows the extension, or comment:" do
      ex = project("a.ex", "") |> Files.ensure_block("a.ex", "x", id: "i")
      assert content(ex, "a.ex") == "# composer:begin i\nx\n# composer:end i\n"

      heex = project("a.heex", "") |> Files.ensure_block("a.heex", "x", id: "i")
      assert content(heex, "a.heex") == "<!-- composer:begin i -->\nx\n<!-- composer:end i -->\n"

      ts = project("a.ts", "") |> Files.ensure_block("a.ts", "x", id: "i")
      assert content(ts, "a.ts") == "/* composer:begin i */\nx\n/* composer:end i */\n"

      sql = project("a.sql", "") |> Files.ensure_block("a.sql", "x", id: "i", comment: {"--", ""})
      assert content(sql, "a.sql") == "-- composer:begin i\nx\n-- composer:end i\n"

      assert_raise ArgumentError, ~r/no comment syntax/, fn ->
        project("a.sql", "") |> Files.ensure_block("a.sql", "x", id: "i")
      end
    end

    test "markers: false matches Templates.insert/4" do
      for at <- [{:after, "one\n"}, {:before, "two"}, :append] do
        igniter = project("notes.txt", "one\ntwo\n")

        assert igniter
               |> Files.ensure_block("notes.txt", "1.5\n", at: at, markers: false)
               |> content("notes.txt") ==
                 igniter |> Templates.insert("notes.txt", "1.5\n", at: at) |> content("notes.txt")
      end

      edit = &Files.ensure_block(&1, "notes.txt", "x", at: {:after, "one"}, markers: false)
      igniter = project("notes.txt", "one\n") |> edit.()

      assert content(igniter, "notes.txt") == "onex\n"
      assert_idempotent(igniter, "notes.txt", edit)
    end

    test "a missing anchor or unclosed marker warns with the suffix" do
      igniter =
        project("app.css", "/* composer:begin x */\n")
        |> Files.ensure_block("app.css", "a", id: "x")
        |> Files.ensure_block("app.css", "a", id: "y", at: {:after, "nope"})

      assert [anchor, unclosed] = igniter.warnings
      assert unclosed =~ "has a composer:begin x marker but no composer:end x"
      assert anchor =~ ~s(could not find "nope" in app.css)
      assert String.ends_with?(anchor, "(Composer.Edit.Files.ensure_block was skipped)")
    end
  end

  describe "replace/5" do
    test "replaces every match, with back-references" do
      igniter =
        project("conf.txt", "port: 4000\nport: 4001\n")
        |> Files.replace("conf.txt", ~r/port: (\d+)/, "port: \\1\\1")

      assert content(igniter, "conf.txt") == "port: 40004000\nport: 40014001\n"
    end

    test "count: limits the replacements" do
      igniter = project("t.txt", "a a a\n")

      assert igniter |> Files.replace("t.txt", ~r/a/, "b", count: 1) |> content("t.txt") ==
               "b a a\n"

      assert igniter |> Files.replace("t.txt", ~r/a/, "b", count: 2) |> content("t.txt") ==
               "b b a\n"
    end

    test "done: as a regex or a function makes a re-run silent" do
      for done <- [~r/port: 4100/, &String.contains?(&1, "4100")] do
        edit = &Files.replace(&1, "conf.txt", ~r/port: 4000/, "port: 4100", done: done)
        igniter = project("conf.txt", "port: 4000\n") |> edit.()

        assert content(igniter, "conf.txt") == "port: 4100\n"
        assert_idempotent(igniter, "conf.txt", edit)
      end
    end

    test "a replacement that matches the pattern again is not re-applied with done:" do
      edit = &Files.replace(&1, "t.txt", ~r/plug :a/, "plug :a\nplug :b", done: ~r/plug :b/)
      igniter = project("t.txt", "plug :a\n") |> edit.()

      assert content(igniter, "t.txt") == "plug :a\nplug :b\n"
      assert_idempotent(igniter, "t.txt", edit)
    end

    test "zero matches without done: warns with the suffix" do
      igniter = project("t.txt", "a\n") |> Files.replace("t.txt", ~r/z/, "y")

      assert_unchanged(igniter, "t.txt")

      assert igniter.warnings == [
               "~r/z/ matched nothing in t.txt (Composer.Edit.Files.replace was skipped)"
             ]
    end
  end
end
