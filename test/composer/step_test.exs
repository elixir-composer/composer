defmodule Composer.StepTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Composer.Step

  test "records metadata, derived from the file path and the options" do
    meta = Composer.FakeBook.Steps.Ash.Postgres.__composer_step__()

    assert meta.id == "ash/postgres"
    assert meta.ref == "fake_book:ash/postgres"
    assert meta.cookbook == "fake_book"
    assert meta.module == Composer.FakeBook.Steps.Ash.Postgres
    assert meta.summary == "Adds AshPostgres"
    assert meta.frameworks == [:ash, :ecto]
    assert meta.tags == ["postgres"]
    assert meta.requires == ["fake_book:hello"]
    assert meta.provides == [:datalayer]
  end

  test "defaults the moduledoc to the summary, and is not a listed Mix task" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Composer.FakeBook.Steps.Hello)
    assert doc == "Writes hello.txt"

    Code.ensure_loaded!(Composer.Core.Steps.Setup.Credo)
    assert Igniter.Mix.Task.igniter_task?(Composer.Core.Steps.Setup.Credo)
    refute Mix.Task.shortdoc(Composer.Core.Steps.Setup.Credo)
  end

  test "Meta.rows/1: the metadata shown by step.show and hover, empty values left out" do
    meta = Composer.FakeBook.Steps.Hello.__composer_step__()

    assert Composer.Step.Meta.rows(meta) == [
             {"action", "gen"},
             {"phase", "setup"},
             {"stability", "stable"},
             {"tags", "greeting"},
             {"module", "Composer.FakeBook.Steps.Hello"}
           ]
  end

  test "path_id/1 and module_for/2 mirror each other" do
    assert Step.path_id("/x/lib/composer/cc_lab/steps/ash/postgres.ex") ==
             {:ok, {"cc_lab", "ash/postgres"}}

    assert Step.path_id("/x/lib/mix/tasks/foo.ex") == :error
    # A leading underscore marks a template directory, never a step.
    assert Step.path_id("/x/lib/composer/cc_lab/steps/_ash/postgres.ex") == :error
    assert Step.path_id("/x/lib/composer/cc_lab/steps/ash/_postgres.ex") == :error

    assert Step.module_for("cc_lab", "ash/postgres") ==
             Composer.CcLab.Steps.Ash.Postgres
  end

  test "template_dir/1 and dir/1 prefix the step's last segment with an underscore" do
    assert Step.template_dir("ash") == "_ash"
    assert Step.template_dir("ash/postgres") == "ash/_postgres"

    assert Step.dir("/x/lib/composer/cc_lab/steps/ash/postgres.ex") ==
             "/x/lib/composer/cc_lab/steps/ash/_postgres"
  end

  defp compile(module, file, opts) do
    Code.compile_string(
      """
      defmodule #{module} do
        use Composer.Step, #{opts}
        def igniter(igniter), do: igniter
      end
      """,
      file
    )
  end

  test "unknown facet values warn at compile time" do
    stderr =
      capture_io(:stderr, fn ->
        compile(
          "Composer.Zed.Steps.Warns",
          "/tmp/lib/composer/zed/steps/warns.ex",
          "phase: :later"
        )
      end)

    assert stderr =~ "unknown phase value :later"
  end

  test "a wrong type is a compile error" do
    assert_raise CompileError, ~r/tags: expected a list/, fn ->
      compile(
        "Composer.Zed.Steps.BadTags",
        "/tmp/lib/composer/zed/steps/bad_tags.ex",
        ~s(tags: "x")
      )
    end
  end

  test "a module name that does not match its path is a compile error" do
    assert_raise CompileError, ~r/must be named Composer.Zed.Steps.Right/, fn ->
      compile(
        "Composer.Zed.Steps.Wrong",
        "/tmp/lib/composer/zed/steps/right.ex",
        "summary: \"x\""
      )
    end
  end

  test "a step outside a steps/ directory is a compile error" do
    assert_raise CompileError, ~r/not inside a cookbook's steps\/ directory/, fn ->
      compile("Composer.Zed.Steps.Lost", "/tmp/lib/elsewhere/lost.ex", "summary: \"x\"")
    end
  end

  describe "template/1" do
    @describetag :tmp_dir

    # Writes the step source under <tmp>/lib/composer/zed/steps/ (with the
    # given files in its template directory) and compiles it.
    defp compile_step(dir, name, body, files) do
      steps = Path.join(dir, "lib/composer/zed/steps")

      for {path, content} <- files do
        file = Path.join([steps, "_" <> name, path])
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, content)
      end

      module = "Composer.Zed.Steps." <> Macro.camelize(name)
      file = Path.join(steps, name <> ".ex")
      File.mkdir_p!(steps)

      Code.compile_string(
        """
        defmodule #{module} do
          use Composer.Step, summary: "x"
          def igniter(_igniter), do: #{body}
        end
        """,
        file
      )
    end

    defp unique(base), do: "#{base}#{System.unique_integer([:positive])}"

    test "a path beside the step compiles to a step-relative reference", %{tmp_dir: dir} do
      name = unique("found")

      [{mod, _}] =
        compile_step(dir, name, ~s|template("sub/a.txt")|, %{"sub/a.txt" => "a"})

      assert mod.igniter(:i) == {"zed", name, "sub/a.txt"}
      assert mod.__composer_templates__() == ["sub/a.txt"]
    end

    test "a missing template is a compile error naming the step and both paths", %{
      tmp_dir: dir
    } do
      error =
        assert_raise CompileError, fn ->
          compile_step(dir, "missing", ~s|template("missing.eex")|, %{"other.txt" => ""})
        end

      message = Exception.message(error)

      assert message =~ ~s|Composer.Zed.Steps.Missing: template "missing.eex" does not exist|
      assert message =~ Path.join(dir, "lib/composer/zed/steps/_missing/missing.eex")
    end

    test "a path outside the step's directory is a compile error", %{tmp_dir: dir} do
      for path <- ["../escape.txt", "/etc/hosts"] do
        assert_raise CompileError, ~r/is outside the step's\s+directory/, fn ->
          compile_step(dir, "escape", ~s|template(#{inspect(path)})|, %{"a.txt" => ""})
        end
      end
    end

    test "a computed path compiles, recorded as :dynamic", %{tmp_dir: dir} do
      name = unique("computed")

      [{mod, _}] =
        compile_step(dir, name, ~s|(n = "a"; template("\#{n}.txt"))|, %{"a.txt" => ""})

      assert mod.igniter(:i) == {"zed", name, "a.txt"}
      assert mod.__composer_templates__() == [:dynamic]
    end
  end
end
