defmodule Composer.LintTest do
  use ExUnit.Case, async: true

  alias Composer.{Cookbook, Discovery, Lint}
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  @fixtures "test/support/fixtures/chapters"

  setup do
    {:ok, cookbooks} = Discovery.cookbooks(apps: [])
    %{cookbooks: cookbooks}
  end

  # Lints a cookbook dir holding the given fixture chapters.
  defp lint(dir, cookbooks, fixtures) do
    File.mkdir_p!(Path.join(dir, "recipes"))

    for name <- fixtures do
      File.cp!(Path.join(@fixtures, name <> ".exs"), Path.join([dir, "recipes", name <> ".exs"]))
    end

    lint_recipes(dir, cookbooks)
  end

  defp errors(result), do: for(%{severity: :error} = d <- result.diagnostics, do: d.message)
  defp warnings(result), do: for(%{severity: :warning} = d <- result.diagnostics, do: d.message)

  defp assert_error(result, pattern) do
    assert Enum.any?(errors(result), &(&1 =~ pattern)),
           "expected an error matching #{inspect(pattern)}, got:\n" <>
             Enum.join(errors(result), "\n")
  end

  test "a clean chapter passes", %{tmp_dir: dir, cookbooks: cookbooks} do
    assert lint(dir, cookbooks, ["clean", "bindings"]).diagnostics == []
  end

  test "each chapter rule fires on its fixture, naming the file and recipe", %{
    tmp_dir: dir,
    cookbooks: cookbooks
  } do
    cases = [
      {"old_format", ~r/old_format.exs must evaluate to a keyword list of recipes/},
      {"not_keyword", ~r/not_keyword.exs must evaluate to a keyword list/},
      {"not_literal", ~r/not_literal.exs must end in a literal keyword list/},
      {"missing_shortdoc", ~r/Recipe mine\/missing_shortdoc\/base has no shortdoc:/},
      {"unknown_key", ~r/Recipe mine\/unknown_key\/base has an unknown key :help/},
      {"bad_value", ~r/Recipe mine\/bad_value\/base has an invalid flags:/},
      {"undeclared_flag", ~r/Recipe mine\/undeclared_flag\/base uses if: :credo/},
      {"reserved_flag", ~r/mine\/reserved_flag\/base declares the flag :(yes|no_commit)/},
      {"duplicate", ~r/duplicate.exs defines the recipe base more than once/},
      {"raises", ~r/Could not evaluate chapter mine\/raises\/.*boom/s},
      {"BadName", ~r/BadName.exs has an invalid name/},
      {"multiline", ~r/mine\/multiline\/base has a shortdoc on more than one line/}
    ]

    for {fixture, pattern} <- cases do
      case_dir = Path.join(dir, fixture)
      assert_error(lint(case_dir, cookbooks, [fixture]), pattern)
    end
  end

  test "an empty chapter is an error", %{tmp_dir: dir, cookbooks: cookbooks} do
    result = lint(dir, cookbooks, ["empty"])
    assert [error] = errors(result)
    assert error =~ "empty.exs holds no recipes"
  end

  test "chapters may be nested in directories", %{tmp_dir: dir, cookbooks: cookbooks} do
    File.mkdir_p!(Path.join(dir, "recipes/ash/ui"))
    File.write!(Path.join(dir, "recipes/ash.exs"), ~s([core: [shortdoc: "C", steps: []]]))
    File.write!(Path.join(dir, "recipes/ash/ui.exs"), ~s([buttons: [shortdoc: "B", steps: []]]))
    File.write!(Path.join(dir, "recipes/ash/ui/tw.exs"), ~s([base: [shortdoc: "T", steps: []]]))

    assert lint_recipes(dir, cookbooks).diagnostics == []

    assert Cookbook.recipes(code_cookbook(dir)) == [
             "ash/core",
             "ash/ui/buttons",
             "ash/ui/tw/base"
           ]
  end

  test "a directory or chapter under recipes/ with an invalid name is an error", %{
    tmp_dir: dir,
    cookbooks: cookbooks
  } do
    File.mkdir_p!(Path.join(dir, "recipes/Ash-UI/deep"))
    File.write!(Path.join(dir, "recipes/Ash-UI/deep/x.exs"), ~s([x: [shortdoc: "X", steps: []]]))
    File.mkdir_p!(Path.join(dir, "recipes/ok"))
    File.write!(Path.join(dir, "recipes/ok/Bad.exs"), ~s([x: [shortdoc: "X", steps: []]]))

    errors = errors(lint_recipes(dir, cookbooks))
    assert Enum.count(errors, &(&1 =~ "recipes/Ash-UI has an invalid name")) == 1
    assert Enum.any?(errors, &(&1 =~ "recipes/ok/Bad.exs has an invalid name"))
    refute Enum.any?(errors, &(&1 =~ "deep/x.exs"))
  end

  test "a leftover profiles/ directory in a package cookbook is an error", %{
    tmp_dir: dir,
    cookbooks: cookbooks
  } do
    name = "legacy#{System.unique_integer([:positive])}"
    root = Path.join([dir, "lib", "composer"])
    File.mkdir_p!(Path.join([root, name, "profiles"]))
    file = Path.join(root, name <> ".ex")
    module = "Composer." <> Macro.camelize(name)
    source = "defmodule #{module} do\n  use Composer.Cookbook, app: :#{name}\nend\n"
    File.write!(file, source)
    [{mod, _}] = Code.compile_string(source, file)

    report = Lint.run(Cookbook.from_module(mod), cookbooks, dir)
    assert_error(report, ~r/#{name}\/profiles is no longer read/)
  end

  test "every recipe must resolve", %{tmp_dir: dir, cookbooks: cookbooks} do
    File.mkdir_p!(Path.join(dir, "recipes"))
    File.write!(Path.join(dir, "recipes/g.exs"), ~s([a: [shortdoc: "A", steps: ["cb_std:nope"]]]))

    assert_error(
      lint_recipes(dir, cookbooks),
      ~r/In recipe mine\/g\/a: no step matches "cb_std:nope"/
    )
  end

  describe "templates" do
    # Compiles a package cookbook in the tmp dir holding the given files.
    defp cookbook(dir, files) do
      name = "tpl#{System.unique_integer([:positive])}"
      root = Path.join([dir, "lib", "composer"])
      # Its own work tree: the tmp dir sits in this repo's ignored tmp/.
      System.cmd("git", ["init", "--quiet", dir])

      for {path, content} <- files do
        file = Path.join([root, name, path])
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, content)
      end

      file = Path.join(root, name <> ".ex")
      module = "Composer." <> Macro.camelize(name)
      source = "defmodule #{module} do\n  use Composer.Cookbook, app: :#{name}\nend\n"
      File.write!(file, source)
      [{mod, _}] = Code.compile_string(source, file)
      {name, Cookbook.from_module(mod)}
    end

    defp errors_matching(report, pattern), do: Enum.filter(errors(report), &(&1 =~ pattern))

    test "a leftover templates/ directory is an error", %{tmp_dir: dir, cookbooks: cookbooks} do
      {name, cookbook} = cookbook(dir, %{"templates/x.txt" => "x"})

      assert_error(
        Lint.run(cookbook, cookbooks, dir),
        ~r/#{name}\/templates is no longer read.*steps\/_<id>\//s
      )
    end

    test "files that no step owns are an error", %{tmp_dir: dir, cookbooks: cookbooks} do
      step = "defmodule X do\n  use Composer.Step\nend\n"

      {name, cookbook} =
        cookbook(dir, %{
          "steps/.gitkeep" => "",
          "steps/_gone/x.txt" => "x",
          "steps/_gone/deeper/y.txt" => "y",
          "steps/ns/a.ex" => step,
          "steps/ns/_a/t.txt" => "t",
          "steps/ns/stray.txt" => "z"
        })

      report = Lint.run(cookbook, cookbooks, dir)

      for orphan <- ["_gone", "ns"] do
        assert_error(report, ~r/#{name}\/steps\/#{orphan} holds files that no step owns/)
      end

      assert_error(report, ~r/steps\/gone.ex does not exist/)
      assert_error(report, ~r/steps\/ns holds .*not a step's template directory/)
      assert errors_matching(report, ~r/_gone\/deeper|_a |steps\/\. |\.gitkeep/) == []
      # Not compiled, so not a step as far as lint can tell.
      assert_error(report, ~r/steps\/ns\/a.ex is a .ex file under steps\/ that is not a step/)
    end

    test "files git ignores are skipped", %{tmp_dir: dir, cookbooks: cookbooks} do
      {_name, cookbook} =
        cookbook(dir, %{
          "steps/.expert/.gitignore" => "*",
          "steps/.expert/expert.log" => "log",
          "steps/junk/x.txt" => "x"
        })

      File.write!(Path.join(dir, ".gitignore"), "junk/\n")

      assert errors_matching(Lint.run(cookbook, cookbooks, dir), ~r/no step owns/) == []
    end

    test "templates in an unprefixed directory are an error", %{
      tmp_dir: dir,
      cookbooks: cookbooks
    } do
      step = "defmodule X do\n  use Composer.Step\nend\n"

      {name, cookbook} =
        cookbook(dir, %{
          "steps/old.ex" => step,
          "steps/old/x.txt" => "x",
          "steps/old/sub/y.txt" => "y"
        })

      report = Lint.run(cookbook, cookbooks, dir)

      assert_error(
        report,
        ~r/#{name}\/steps\/old holds templates of .*steps\/old.ex.*Rename it to \S*#{name}\/steps\/_old;/s
      )

      assert errors_matching(report, ~r/no step owns/) == []
    end

    test "a path dep in a project with a package: section warns", %{tmp_dir: dir} do
      {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book])
      cookbook = Cookbook.from_module(Composer.FakeBook)

      File.write!(Path.join(dir, "mix.exs"), """
      defp deps do
        [{:composer, path: "../composer"},
         {:jason, "~> 1.4"},
         {:a, "~> 1.0", path: "a"}]
      end
      """)

      deps = [{:composer, path: "../composer"}, {:jason, "~> 1.4"}, {:a, "~> 1.0", path: "a"}]
      path_dep = ~r/path dependency, but this project has a package: section/

      published = Lint.run(cookbook, cookbooks, dir, project: [package: [], deps: deps])
      messages = Enum.filter(warnings(published), &(&1 =~ path_dep))
      assert length(messages) == 2
      assert Enum.any?(messages, &(&1 =~ ":composer"))
      assert Enum.any?(messages, &(&1 =~ ":a "))

      lines =
        for %{code: :path_dep_in_package} = d <- published.diagnostics, do: d.line

      assert Enum.sort(lines) == [2, 4]
      assert errors_matching(published, path_dep) == []

      private = Lint.run(cookbook, cookbooks, dir, project: [deps: deps])
      refute Enum.any?(warnings(private), &(&1 =~ path_dep))
      refute Enum.any?(warnings(Lint.run(cookbook, cookbooks, dir)), &(&1 =~ path_dep))
    end

    test "fake_book: child-step directories pass; unreferenced templates warn", %{tmp_dir: dir} do
      {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book])
      report = Lint.run(Cookbook.from_module(Composer.FakeBook), cookbooks, dir)

      # steps/ash/ holds only the child step postgres.ex, with no ash.ex.
      assert errors_matching(report, ~r/no step owns|not a step|does not exist \(looked/) == []

      unused =
        for warning <- warnings(report),
            [_, file] <- [Regex.run(~r{steps/(\S+) is never referred to}, warning)],
            do: file

      # hello_templates uses only greeting.txt.eex; dynamic_templates computes
      # its path, so it is not checked.
      assert unused == [
               "_hello_templates/layouts/app_fn.ex.eex",
               "_hello_templates/page/.gitkeep",
               "_hello_templates/page/README.md",
               "_hello_templates/page/__web_dir__/components/hello.ex.eex",
               "_hello_templates/page/docs/.keep",
               "_hello_templates/raw.heex"
             ]
    end
  end

  describe "cookbook aliases" do
    defp lint_chapter(dir, source) do
      File.mkdir_p!(Path.join(dir, "recipes"))
      File.write!(Path.join([dir, "recipes", "g.exs"]), source)
      {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book, :other_book])
      lint_recipes(dir, cookbooks)
    end

    test "a used, consistent alias is clean", %{tmp_dir: dir} do
      assert lint_chapter(dir, File.read!(Path.join(@fixtures, "aliases.exs"))).diagnostics == []
    end

    test "unused and inconsistent aliases are warnings", %{tmp_dir: dir} do
      report =
        lint_chapter(dir, """
        [
          a: [shortdoc: "x", aliases: [fb: "fake_book", ob: "other_book"], steps: ["fb:hello"]],
          b: [shortdoc: "x", aliases: [fb: "other_book"], steps: ["fb:hello"]]
        ]
        """)

      assert errors(report) == []

      assert [inconsistent, unused] = report.diagnostics
      assert unused.message =~ "mine/g/a: alias ob (= other_book) is never used"
      # Both at the alias they are about: line 2, `fb:` then `ob:`.
      assert {unused.code, unused.line, unused.column} == {:unused_alias, 2, 49}

      assert inconsistent.message =~
               "alias fb names different cookbooks: fake_book in g/a, other_book in g/b"

      assert {inconsistent.code, inconsistent.line, inconsistent.column} ==
               {:inconsistent_alias, 2, 32}
    end

    test "an alias colliding with a cookbook or reserved name is an error", %{tmp_dir: dir} do
      shadowing =
        lint_chapter(Path.join(dir, "shadowing"), """
        [a: [shortdoc: "x", aliases: [other_book: "fake_book"], steps: ["other_book:hello"]]]
        """)

      assert_error(
        shadowing,
        ~r/mine\/g\/a declares the alias other_book:, but other_book is an installed cookbook/
      )

      reserved =
        lint_chapter(Path.join(dir, "reserved"), """
        [b: [shortdoc: "x", aliases: [cb_std: "fake_book"], steps: []]]
        """)

      assert_error(reserved, ~r/mine\/g\/b declares the alias cb_std:, but cb_std is a reserved/)
    end
  end
end
