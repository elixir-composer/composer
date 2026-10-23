defmodule Composer.Lint.FormatTest do
  use ExUnit.Case, async: true

  alias Composer.Lint.{Diagnostic, Format}

  @file_path "/home/me/src/mine/lib/composer/mine/recipes/g.exs"

  defp diagnostics do
    [
      Diagnostic.new(:warning, {:unused_alias, "mine:g/a", :lab, "cc_lab"})
      |> Diagnostic.locate(@file_path, {{1, 12}, {1, 16}}),
      Diagnostic.new(:error, {:missing_step, "core:nope", "mine:g/a", []})
      |> Diagnostic.locate(@file_path, {{3, 7}, {3, 18}}),
      Diagnostic.new(:error, {:invalid_entry, "mine:g/b", {:nope}})
      |> Diagnostic.locate(@file_path, {{5, 7}, {5, 14}}),
      Diagnostic.new(:error, {:duplicate_cookbook, "x", [X.One, X.Two]})
    ]
  end

  test "compact: one line each, absolute paths, folded messages, a fallback location" do
    assert Format.compact(diagnostics(), "/project/lib/composer/x/manifest.exs") == """
           #{@file_path}:1:12: warning: mine:g/a: alias lab (= cc_lab) is never used. Remove it, or use it. [unused_alias]
           #{@file_path}:3:7: error: In recipe mine:g/a: no step matches "core:nope". List steps with: mix composer.step.list [missing_step]
           #{@file_path}:5:7: error: Invalid entry in recipe mine:g/b: {:nope} Expected one of: [invalid_entry]
           /project/lib/composer/x/manifest.exs:1:1: error: More than one cookbook is named "x": X.One, X.Two. A cookbook is named after its package, so each name must come from one package. Remove one of them from your dependencies, or exclude it with config :composer, cookbooks: [except: [...]]. [duplicate_cookbook]\
           """
  end

  test "json: an array of diagnostics with ranges, suggestions and related" do
    typo =
      Diagnostic.new(:error, {:typo, "credoo", "mine:g/a", ["core:setup/credo"]})
      |> Diagnostic.locate(@file_path, {{3, 7}, {3, 15}}, [
        %{file: "/other.exs", range: {{1, 1}, {1, 4}}, message: "here"}
      ])

    assert [decoded] = typo |> List.wrap() |> Format.json() |> Jason.decode!()

    assert decoded == %{
             "severity" => "error",
             "code" => "typo",
             "file" => @file_path,
             "line" => 3,
             "column" => 7,
             "end_line" => 3,
             "end_column" => 15,
             "message" => typo.message,
             "suggestions" => ["core:setup/credo"],
             "related" => [
               %{
                 "file" => "/other.exs",
                 "line" => 1,
                 "column" => 1,
                 "end_line" => 1,
                 "end_column" => 4,
                 "message" => "here"
               }
             ]
           }

    assert Format.json([]) == "[]"
  end

  test "github: workflow commands with escaped properties" do
    [warning, error | _] = diagnostics()

    assert Format.github([warning, error]) == """
           ::warning file=#{@file_path},line=1,col=12,endLine=1,endColumn=16,title=composer lint [unused_alias]::mine:g/a: alias lab (= cc_lab) is never used. Remove it, or use it.
           ::error file=#{@file_path},line=3,col=7,endLine=3,endColumn=18,title=composer lint [missing_step]::In recipe mine:g/a: no step matches "core:nope". List steps with: mix composer.step.list\
           """

    odd = %{error | file: "/tmp/a,b:c.exs", message: "100% sure"}
    assert Format.github([odd]) =~ "file=/tmp/a%2Cb%3Ac.exs,"
    assert Format.github([odd]) =~ "::100%25 sure"
  end

  test "text: full messages after their location, errors and warnings apart" do
    %{errors: [missing, invalid, duplicate], warnings: [unused]} = Format.text(diagnostics())

    assert unused =~
             ~r{^/home/me/src/mine/lib/composer/mine/recipes/g.exs:1:12: mine:g/a: alias lab}

    assert missing =~ ~r{g.exs:3:7: In recipe mine:g/a: no step matches}
    # Text keeps the example list that compact drops.
    assert invalid =~ ~s({"cookbook:path", if: :flag})
    assert duplicate =~ ~r/^More than one cookbook/
  end

  test "fold drops indented blocks and joins lines" do
    assert Format.fold("One.\n\n    code\n    more\n\nTwo\nthree.\n") == "One. Two three."
    assert Format.fold("Keep:\n    not a block after text") == "Keep: not a block after text"
  end
end
