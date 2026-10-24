defmodule Composer.Lint.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Composer.{Discovery, Error, Lint}
  alias Composer.Lint.Diagnostic
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  @anchors "test/support/fixtures/anchors"

  setup do
    {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book, :other_book])
    %{cookbooks: cookbooks}
  end

  defp config(dir, groups) do
    File.mkdir_p!(Path.join(dir, "recipes"))
    for {name, source} <- groups, do: File.write!(Path.join([dir, "recipes", name]), source)
    dir
  end

  defp anchors(dir, cookbooks) do
    File.mkdir_p!(Path.join(dir, "recipes"))

    for file <- Path.wildcard(Path.join(@anchors, "*.exs")),
        do: File.cp!(file, Path.join([dir, "recipes", Path.basename(file)]))

    lint_recipes(dir, cookbooks).diagnostics
  end

  defp at(diagnostic), do: {Path.basename(diagnostic.file), diagnostic.line, diagnostic.column}
  defp find(diagnostics, code), do: Enum.find(diagnostics, &(&1.code == code))

  describe "anchors" do
    test "every recipe problem is placed in its file, away from line 1", %{
      tmp_dir: dir,
      cookbooks: cookbooks
    } do
      diagnostics = anchors(dir, cookbooks)

      for d <- diagnostics do
        assert d.file && d.line && d.line > 1, "#{d.code} is not located: #{inspect(d)}"
        assert d.end_line && d.end_column
      end

      expected =
        ~w(recipe_missing_key unknown_recipe_key bad_recipe_value undeclared_flag
           multiline_shortdoc recipe_shape invalid_recipe_name duplicate_recipe invalid_alias
           reserved_alias duplicate_alias alias_atom_target invalid_alias_target legacy_form
           invalid_entry unknown_entry_option bad_entry_option hex_only_option multiple_sources
           git_option_without_git multiple_git_refs source_conflict repo_source invalid_ref
           recipe_eval inconsistent_alias missing_step typo unknown_cookbook
           ambiguous dep_opts_on_step unknown_alias_target via_alias missing_recipe
           alias_shadows_cookbook unused_alias conflicting_install cycle group_recipe_clash
           reserved_flag)a

      assert expected -- Enum.map(diagnostics, & &1.code) == []
    end

    test "each anchor kind points at what it is about", %{tmp_dir: dir, cookbooks: cookbooks} do
      diagnostics = anchors(dir, cookbooks)

      # {:ref, origin, written}: the literal, quotes included.
      typo = find(diagnostics, :typo)
      assert at(typo) == {"refs.exs", 10, 7}
      assert {typo.end_line, typo.end_column} == {10, 15}
      assert typo.suggestions == ["cb_std:setup/credo", "fake_book:setup/credo"]
      # Behind an alias, at the reference as written.
      assert at(find(diagnostics, :via_alias)) == {"refs.exs", 16, 7}
      assert at(find(diagnostics, :unknown_alias_target)) == {"refs.exs", 15, 7}
      # {:entry, recipe, entry}: the whole entry.
      legacy = find(diagnostics, :legacy_form)
      assert {at(legacy), legacy.end_column} == {{"keys.exs", 21, 7}, 27}
      # {:recipe_key, recipe, key}, and the if: flag of an undeclared flag.
      assert at(find(diagnostics, :unknown_recipe_key)) == {"keys.exs", 4, 32}
      assert at(find(diagnostics, :undeclared_flag)) == {"keys.exs", 6, 66}
      # {:alias, recipe, name}: in the recipe, or in the binding it names.
      assert at(find(diagnostics, :invalid_alias)) == {"keys.exs", 14, 15}
      assert at(find(diagnostics, :inconsistent_alias)) == {"refs.exs", 2, 12}
      # {:recipe, ref} and {:recipe_named, cookbook, name}: the name key.
      assert at(find(diagnostics, :recipe_shape)) == {"keys.exs", 8, 3}
      assert at(find(diagnostics, :group_recipe_clash)) == {"refs.exs", 27, 3}
      # {:file, path, line}: the whole line the exception names.
      eval = Enum.find(diagnostics, &(&1.code == :recipe_eval and &1.file =~ "raises"))
      assert {at(eval), eval.end_column} == {{"raises.exs", 3, 1}, 18}
    end

    test "problems involving several places fill related", %{tmp_dir: dir, cookbooks: cookbooks} do
      diagnostics = anchors(dir, cookbooks)

      duplicate = find(diagnostics, :duplicate_recipe)
      assert at(duplicate) == {"keys.exs", 11, 3}
      assert [%{range: {{10, 3}, _}, message: "dup is first defined here"}] = duplicate.related

      install = find(diagnostics, :conflicting_install)
      assert at(install) == {"refs.exs", 24, 36}

      assert [%{range: {{24, 49}, _}, message: "also installed as hex:oban --x"}] =
               install.related

      assert [cycle | _] = Enum.filter(diagnostics, &(&1.code == :cycle))
      assert at(cycle) == {"refs.exs", 25, 42}
      assert [%{range: {{26, 42}, _}, message: message}] = cycle.related
      assert message =~ "includes"
    end

    test "a cycle across files relates every hop", %{tmp_dir: dir, cookbooks: cookbooks} do
      config(dir, %{
        "a.exs" => ~s|[one: [shortdoc: "x", steps: [{:use, "mine:b/two"}]]]\n|,
        "b.exs" => ~s|[two: [shortdoc: "x", steps: [{:use, "mine:a/one"}]]]\n|
      })

      cycles = Enum.filter(lint_recipes(dir, cookbooks).diagnostics, &(&1.code == :cycle))
      assert length(cycles) == 2

      for cycle <- cycles do
        assert [%{file: other}] = cycle.related
        assert Path.basename(other) != Path.basename(cycle.file)
      end
    end

    test "a step's problems are placed in its source", %{tmp_dir: dir} do
      {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book])
      cookbook = Composer.Cookbook.from_module(Composer.FakeBook)
      diagnostics = Lint.run(cookbook, cookbooks, dir).diagnostics

      missing =
        Enum.find(diagnostics, &match?({:missing_step_test, "fake_book:hello", _, _}, &1.reason))

      assert missing.file =~ "fake_book/steps/hello.ex"
      source = File.read!(missing.file) |> String.split("\n") |> Enum.at(missing.line - 1)
      assert String.slice(source, missing.column - 1, 17) == "use Composer.Step"
      assert [%{file: test_file}] = missing.related
      assert test_file == Path.join(dir, "test/composer/fake_book/steps/hello_test.exs")
    end
  end

  describe "the anchor guard" do
    # Every tag message/1 renders must have an anchor/1 clause, so a new
    # error kind cannot quietly lose its position.
    test "anchor/1 covers every message/1 reason" do
      {:ok, ast} = "lib/composer/error.ex" |> File.read!() |> Code.string_to_quoted()

      messages = clause_tags(ast, :message)
      anchors = clause_tags(ast, :anchor)

      assert messages != [] and anchors != []
      assert messages -- anchors == []
    end

    test "anchor/1 is :unknown only for what it does not know" do
      assert Error.anchor({:no_such_reason, 1}) == :unknown
      assert Error.anchor({:typo, "x", "mine:a/b", []}) == {:ref, "mine:a/b", "x"}

      assert Error.anchor(
               {:via_alias, "lab:x", :lab, "cc_lab", {:missing_step, "cc_lab:x", "mine:a/b", []}}
             ) ==
               {:ref, "mine:a/b", "lab:x"}
    end

    defp clause_tags(ast, name) do
      {_ast, tags} =
        Macro.prewalk(ast, [], fn
          {:def, _, [head | _]} = node, acc -> {node, tags(head, name) ++ acc}
          node, acc -> {node, acc}
        end)

      Enum.uniq(tags)
    end

    defp tags({:when, _, [{name, _, [pattern]}, guard]}, name), do: pattern_tags(pattern, guard)
    defp tags({name, _, [pattern]}, name), do: pattern_tags(pattern, nil)
    defp tags(_head, _name), do: []

    defp pattern_tags({:{}, _, [tag | rest]}, guard), do: tag_names(tag, guard, length(rest) + 1)
    defp pattern_tags({tag, _second}, guard), do: tag_names(tag, guard, 2)
    defp pattern_tags(tag, _guard) when is_atom(tag), do: [{tag, 0}]
    defp pattern_tags(_pattern, _guard), do: []

    defp tag_names(tag, _guard, arity) when is_atom(tag), do: [{tag, arity}]

    defp tag_names({var, _, _}, {:in, _, [{var, _, _}, tags]}, arity) when is_list(tags),
      do: for(tag <- tags, do: {tag, arity})

    defp tag_names(_tag, _guard, _arity), do: []
  end

  describe "all errors per recipe" do
    test "three typos give three diagnostics, none repeated by the deep pass", %{
      tmp_dir: dir,
      cookbooks: cookbooks
    } do
      config(dir, %{
        "g.exs" => ~s|[a: [shortdoc: "x", steps: ["credoo", "cb_std:nope", "gitignor"]]]\n|
      })

      diagnostics = lint_recipes(dir, cookbooks).diagnostics

      assert Enum.map(diagnostics, &{&1.code, &1.column}) == [
               {:typo, 29},
               {:missing_step, 39},
               {:typo, 54}
             ]
    end

    test "a typo in an included recipe is reported once, at its origin", %{
      tmp_dir: dir,
      cookbooks: cookbooks
    } do
      config(dir, %{
        "ash.exs" => ~s|[\n  base: [shortdoc: "x", steps: ["credoo"]]\n]\n|,
        "app.exs" =>
          ~s|[\n  full: [shortdoc: "x", steps: [{:use, "mine:ash/base"}]],\n  more: [shortdoc: "x", steps: [{:use, "mine:ash/base"}]]\n]\n|
      })

      assert [typo] = lint_recipes(dir, cookbooks).diagnostics
      assert at(typo) == {"ash.exs", 2, 33}
    end
  end

  describe "files/3" do
    setup %{tmp_dir: dir, cookbooks: cookbooks} do
      config(dir, %{
        "ash.exs" =>
          ~s|[\n  base: [shortdoc: "x", steps: ["credoo", "cb_std:nope"]],\n  mid: [shortdoc: "x", steps: [{:use, "base"}]]\n]\n|,
        "app.exs" =>
          ~s|[\n  full: [shortdoc: "x", steps: [{:use, "mine:ash/mid"}, "cb_std:setup/gitignore"]]\n]\n|,
        "clean.exs" => ~s|[\n  ok: [shortdoc: "x", steps: ["cb_std:setup/gitignore"]]\n]\n|
      })

      %{
        app: Path.join(dir, "recipes/app.exs"),
        ash: Path.join(dir, "recipes/ash.exs"),
        cookbooks: cookbooks ++ [code_cookbook(dir)]
      }
    end

    test "reports a file's own problems, and a summary at each broken include", %{
      tmp_dir: dir,
      cookbooks: cookbooks,
      app: app,
      ash: ash
    } do
      clean = Path.join(dir, "recipes/clean.exs")
      results = Lint.files(cookbooks, [app, ash, clean])

      assert results[clean] == []
      assert Enum.map(results[ash], & &1.code) == [:typo, :missing_step, :include_problems]

      # Included through ash/mid: the problems below it count.
      assert [summary] = results[app]
      assert %Diagnostic{code: :include_problems, severity: :error, file: ^app} = summary
      assert {summary.line, summary.column} == {2, 40}
      assert summary.message == "mine:ash/mid has 2 problems."

      assert Enum.map(summary.related, &{Path.basename(&1.file), elem(elem(&1.range, 0), 0)}) == [
               {"ash.exs", 2},
               {"ash.exs", 2}
             ]
    end

    test "dependents are found through other includes", %{
      cookbooks: cookbooks,
      app: app,
      ash: ash
    } do
      assert Lint.dependents(cookbooks, "mine:ash/base") == [
               %{ref: "mine:app/full", path: app},
               %{ref: "mine:ash/mid", path: ash}
             ]

      assert Lint.dependents(cookbooks, "mine:app/full") == []
    end

    test "the cookbook of a file is found from its path", %{
      tmp_dir: dir,
      cookbooks: cookbooks,
      app: app
    } do
      assert {:ok, %{name: "mine"}} = Lint.owner(cookbooks, app)

      fake =
        Path.join(
          Composer.Cookbook.source_dir(Composer.Cookbook.from_module(Composer.FakeBook)),
          "recipes/main.exs"
        )

      assert {:ok, %{name: "fake_book"}} = Lint.owner(cookbooks, fake)

      assert {:error, {:lint_file_unknown, _}} = Lint.owner(cookbooks, "mix.exs")

      assert {:error, {:lint_file_missing, _}} =
               Lint.owner(cookbooks, Path.join(dir, "nope.exs"))
    end

    test "a file reached through a symbolic link is matched", %{
      tmp_dir: dir,
      cookbooks: cookbooks
    } do
      link = Path.join(Path.dirname(dir), "link-#{System.unique_integer([:positive])}")
      File.ln_s!(dir, link)
      on_exit(fn -> File.rm(link) end)

      path = Path.join(link, "recipes/ash.exs")
      assert {:ok, %{name: "mine"}} = Lint.owner(cookbooks, path)
      assert [_ | _] = Lint.files(cookbooks, [path])[path]
    end
  end
end
