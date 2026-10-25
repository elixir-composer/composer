defmodule Composer.Lint.FixTest do
  use ExUnit.Case, async: true

  alias Composer.{Discovery, Lint}
  alias Composer.Lint.Fix
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  @fixtures "test/support/fixtures/old_syntax"

  # Lints and fixes until nothing is left to fix, as --fix does.
  defp fix_all(lint, rounds \\ 10) do
    result = lint.()

    case Fix.apply(result.diagnostics) do
      %{fixed: []} -> result
      _ when rounds > 0 -> fix_all(lint, rounds - 1)
    end
  end

  test "rewrites an old-syntax chapter in place, keeping comments and layout", %{tmp_dir: dir} do
    {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book, :other_book])
    File.mkdir_p!(Path.join(dir, "recipes"))
    chapter = Path.join(dir, "recipes/app.exs")
    File.cp!(Path.join(@fixtures, "before.exs"), chapter)

    result = fix_all(fn -> lint_recipes(dir, cookbooks) end)

    assert File.read!(chapter) == File.read!(Path.join(@fixtures, "after.exs"))

    # What could not be rewritten is still reported.
    left = Enum.map(result.diagnostics, &{&1.code, &1.line})
    assert {:old_syntax, 23} in left
    assert {:use_entry, 24} in left
    assert Enum.all?(result.diagnostics, &(&1.fix == nil))
  end

  test "a fix applies only while its range still holds the literal" do
    source = ~s(["cb_std:setup/credo"]\n)

    fix = fn expect, text ->
      %Composer.Lint.Diagnostic{
        code: :old_syntax,
        file: "x.exs",
        fix: %{range: {{1, 2}, {1, 22}}, expect: expect, text: text}
      }
    end

    assert {~s(["cb_std:setup:credo"]\n), [_], []} =
             Fix.rewrite(source, [fix.("cb_std:setup/credo", ~s("cb_std:setup:credo"))])

    assert {^source, [], [_]} = Fix.rewrite(source, [fix.("something else", ~s("x"))])
  end

  test "fixes a step module's old-syntax requires", %{tmp_dir: dir} do
    name = "fixreq#{System.unique_integer([:positive])}"
    module = "Composer.#{Macro.camelize(name)}"
    root = Path.join([dir, "lib", "composer"])
    step_file = Path.join([root, name, "steps", "needs.ex"])
    File.mkdir_p!(Path.dirname(step_file))

    File.write!(Path.join(root, name <> ".ex"), """
    defmodule #{module} do
      use Composer.Cookbook, app: :#{name}
    end
    """)

    File.write!(step_file, """
    defmodule #{module}.Steps.Needs do
      use Composer.Step,
        summary: "Needs libcluster",
        action: :add,
        stability: :stable,
        # Old syntax, which still compiles with a warning.
        requires: ["cb_std:cluster/libcluster", "hex:oban"]

      @impl Igniter.Mix.Task
      def igniter(igniter), do: igniter
    end
    """)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_file(Path.join(root, name <> ".ex"))
      Code.compile_file(step_file)
    end)

    # A cookbook's steps are its app's modules: give these an app.
    app = String.to_atom(name)
    modules = [Module.concat([module]), Module.concat([module, Steps, Needs])]
    :ok = :application.load({:application, app, [modules: modules, vsn: ~c"0.1.0"]})
    on_exit(fn -> :application.unload(app) end)

    book = %{Composer.Cookbook.from_module(Module.concat([module])) | app: app}
    {:ok, cookbooks} = Discovery.cookbooks(apps: [], cookbooks: [book])

    result = Lint.run(book, cookbooks, dir)
    assert [old] = Enum.filter(result.diagnostics, &(&1.code == :old_requires))
    assert old.fix.text == ~s("cb_std:cluster:libcluster")

    Fix.apply(result.diagnostics)
    assert File.read!(step_file) =~ ~s(requires: ["cb_std:cluster:libcluster", "hex:oban"])
    assert File.read!(step_file) =~ "# Old syntax, which still compiles with a warning."
  end
end
