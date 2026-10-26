defmodule Composer.CookbookTest do
  use ExUnit.Case, async: true

  alias Composer.Cookbook

  @moduletag :tmp_dir

  # Writes lib/composer/<name>.ex (and optional files under lib/composer/<name>/)
  # into a tmp dir and compiles the cookbook module with the given app.
  defp compile(dir, module, name, app, files \\ %{}) do
    root = Path.join([dir, "lib", "composer"])

    for {path, content} <- files do
      file = Path.join([root, name, path])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    file = Path.join(root, name <> ".ex")
    File.mkdir_p!(root)
    source = "defmodule #{module} do\n  use Composer.Cookbook, app: #{inspect(app)}\nend\n"
    File.write!(file, source)
    Code.compile_string(source, file)
  end

  defp unique(base), do: "#{base}#{System.unique_integer([:positive])}"

  test "the fixture cookbook records its metadata and recipes" do
    info = Composer.FakeBook.__composer_cookbook__()

    assert info.name == "fake_book"
    assert info.app == :fake_book
    assert info.summary == "A fixture cookbook"
    assert "nested/extra" in info.recipes
    assert String.ends_with?(info.source_dir, "cookbooks/fake_book/lib/composer/fake_book")
  end

  describe "nested chapters" do
    setup do
      %{book: Cookbook.from_module(Composer.NestedBook)}
    end

    test "are discovered under recipes/**, by chapter path", %{book: book} do
      assert Enum.map(Cookbook.chapters(book), &elem(&1, 0)) ==
               ["ash", "ash/ui", "ash/ui/tailwind", "ash/ui/tailwind/forms"]

      assert Cookbook.recipes(book) == [
               "ash/core",
               "ash/ui/buttons",
               "ash/ui/tailwind/base",
               "ash/ui/tailwind/forms/inputs",
               "ash/ui/tailwind/full"
             ]

      assert "ash/ui/tailwind/forms/inputs" in Composer.NestedBook.__composer_cookbook__().recipes
    end

    test "a recipe's file is found by splitting off its last segment", %{book: book} do
      assert Cookbook.recipe_path(book, "ash/ui/buttons") =~ ~r{recipes/ash/ui\.exs\z}

      assert Cookbook.recipe_path(book, "ash/ui/tailwind/base") =~
               ~r{recipes/ash/ui/tailwind\.exs\z}

      assert Cookbook.recipe_path(book, "ash/ui/tailwind") == nil
      assert Cookbook.recipe_path(book, "core") == nil
    end

    test "recipes know their chapter path", %{book: book} do
      {recipes, []} = Cookbook.load_recipes(book)
      inputs = Enum.find(recipes, &(&1.name == "inputs"))
      assert inputs.chapter == "ash/ui/tailwind/forms"
      assert inputs.id == "ash/ui/tailwind/forms/inputs"
    end
  end

  test "a chapter in a directory with an invalid name fails", %{tmp_dir: dir} do
    name = unique("bad_dir")

    assert_raise CompileError, ~r/invalid name/, fn ->
      compile(dir, "Composer.#{Macro.camelize(name)}", name, String.to_atom(name), %{
        "recipes/Ui/base.exs" => "[a: [shortdoc: \"x\", steps: []]]"
      })
    end
  end

  test "steps are enumerated from the cookbook's modules, sorted by id" do
    ids = Composer.FakeBook |> Cookbook.from_module() |> Cookbook.steps() |> Enum.map(& &1.id)
    assert ids == Enum.sort(ids)
    assert "ash/postgres" in ids and "hello" in ids

    cb_std = Cookbook.from_module(Composer.CbStd)
    assert length(Cookbook.steps(cb_std)) == 32

    assert {:ok, %{ref: "cb_std:cluster:gigalixir:libcluster"}} =
             Cookbook.step(cb_std, "cluster/gigalixir/libcluster")
  end

  test "a name that matches the app compiles", %{tmp_dir: dir} do
    name = unique("good")
    module = "Composer." <> Macro.camelize(name)
    [{mod, _}] = compile(dir, module, name, String.to_atom(name))
    assert mod.__composer_cookbook__().name == name
  end

  test "a name that does not match the app fails", %{tmp_dir: dir} do
    assert_raise CompileError, ~r/but this\s+package's OTP app is :other/, fn ->
      compile(dir, "Composer.Mismatch", "mismatch", :other)
    end
  end

  # Reserved names are composer's own modules, so compiling them here would
  # redefine the real ones; run the checks against a synthetic env instead.
  defp define(module, app) do
    name = module |> Module.split() |> List.last() |> Macro.underscore()
    env = %{__ENV__ | module: module, file: "/tmp/lib/composer/#{name}.ex", line: 1}
    Cookbook.define!(env, app: app)
  end

  test "reserved names fail" do
    for {module, app} <- [
          {Composer.Hex, :hex},
          {Composer.Local, :local},
          {Composer.Runner, :runner}
        ] do
      assert_raise CompileError, ~r/is reserved by composer/, fn -> define(module, app) end
    end

    assert_raise CompileError, ~r/reserved for composer's built-in cookbook/, fn ->
      define(Composer.CbStd, :cb_std)
    end
  end

  test "a nested module fails" do
    assert_raise CompileError, ~r/one level below Composer/, fn ->
      define(Composer.Foo.Bar, :bar)
    end
  end

  test "a chapter file with an invalid name fails", %{tmp_dir: dir} do
    assert_raise CompileError, ~r/Chapter .*lv-base.exs has an invalid name/, fn ->
      compile(dir, "Composer.Badchapter", "badchapter", :badchapter, %{
        "recipes/lv-base.exs" => "[]"
      })
    end
  end

  test "recipes are chapter-path/name ids read from chapter files, nested too", %{tmp_dir: dir} do
    name = unique("chaptered")

    [{mod, _}] =
      compile(dir, "Composer." <> Macro.camelize(name), name, String.to_atom(name), %{
        "recipes/ash.exs" => "[base: [shortdoc: \"B\", steps: []], auth: raise(\"never\")]",
        "recipes/nested/x.exs" => "[x: []]"
      })

    assert mod.__composer_cookbook__().recipes == ["ash/auth", "ash/base", "nested/x/x"]
  end

  test "chapters under a leftover profiles/ directory are not read", %{tmp_dir: dir} do
    name = unique("legacy")

    [{mod, _}] =
      compile(dir, "Composer." <> Macro.camelize(name), name, String.to_atom(name), %{
        "profiles/ash.exs" => "[base: [shortdoc: \"B\", steps: []]]"
      })

    assert mod.__composer_cookbook__().recipes == []
  end

  test "the old Registry and Profile modules are gone" do
    refute Code.ensure_loaded?(Composer.Registry)
    refute Code.ensure_loaded?(Composer.Profile)
  end

  test "a recipe that does not parse fails", %{tmp_dir: dir} do
    assert_raise CompileError, ~r/chapter .*broken.exs does not parse/, fn ->
      compile(dir, "Composer.Parsefail", "parsefail", :parsefail, %{
        "recipes/broken.exs" => File.read!("test/support/fixtures/syntax_error.exs")
      })
    end
  end

  test "a .ex under steps/ that is not a step fails, naming the rename", %{tmp_dir: dir} do
    assert_raise CompileError,
                 ~r/steps\/s\/layout.ex is a .ex file under steps\/ that is not.*rename it to layout.ex.eex.*Composer.Bareex.Steps.S.Layout/s,
                 fn ->
                   compile(dir, "Composer.Bareex", "bareex", :bareex, %{
                     "steps/s.ex" =>
                       "defmodule Composer.Bareex.Steps.S do\n  use Composer.Step\nend\n",
                     "steps/s/layout.ex" => "<%= @x %>"
                   })
                 end
  end

  test "a leftover templates/ directory does not fail compilation", %{tmp_dir: dir} do
    name = unique("oldtpl")

    [{mod, _}] =
      compile(dir, "Composer." <> Macro.camelize(name), name, String.to_atom(name), %{
        "templates/x.txt" => "x"
      })

    assert mod.__composer_cookbook__().name == name
  end

  test "__mix_recompile__?/0 flips when a template is added beside a step", %{tmp_dir: dir} do
    name = unique("recomptpl")
    [{mod, _}] = compile(dir, "Composer." <> Macro.camelize(name), name, String.to_atom(name))
    refute mod.__mix_recompile__?()

    step_dir = Path.join([dir, "lib", "composer", name, "steps", "_s"])
    File.mkdir_p!(step_dir)
    File.write!(Path.join(step_dir, "new.txt.eex"), "x\n")
    assert mod.__mix_recompile__?()
  end

  test "__mix_recompile__?/0 flips when a recipe is added", %{tmp_dir: dir} do
    name = unique("recomp")
    [{mod, _}] = compile(dir, "Composer." <> Macro.camelize(name), name, String.to_atom(name))
    refute mod.__mix_recompile__?()

    File.mkdir_p!(Path.join([dir, "lib", "composer", name, "recipes"]))
    File.write!(Path.join([dir, "lib", "composer", name, "recipes", "new.exs"]), "[]\n")
    assert mod.__mix_recompile__?()
  end

  test "every top-level composer module name is reserved" do
    {:ok, modules} = :application.get_key(:composer, :modules)

    top_level =
      for module <- modules,
          ["Composer", segment | _] <- [Module.split(module)],
          name = Macro.underscore(segment),
          name not in ["fake_book", "other_book", "nested_book", "test"],
          uniq: true,
          do: name

    assert top_level -- Cookbook.reserved() == []
  end
end
