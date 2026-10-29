defmodule Composer.ManifestTest do
  use ExUnit.Case, async: true

  alias Composer.{Discovery, Index, Lint, Manifest, Cookbook}
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  test "build/1 is plain data, sorted by id, and render/1 is deterministic" do
    cookbook = Cookbook.from_module(Composer.FakeBook)
    data = Manifest.build(cookbook)

    assert data.name == "fake_book"
    assert Enum.map(data.steps, & &1.id) == Enum.sort(Enum.map(data.steps, & &1.id))
    assert %{id: "fake_book/main/base", shortdoc: "The base recipe"} in data.recipes
    assert Enum.any?(data.steps, &(&1.id == "fake_book:ash:postgres"))

    rendered = Manifest.render(data)
    assert rendered == Manifest.render(Manifest.build(cookbook))
    assert {^data, _} = Code.eval_string(rendered)
  end

  test "cb_std's committed manifest is up to date" do
    cb_std = Cookbook.from_module(Composer.CbStd)

    assert File.read!(Manifest.path(cb_std)) == Manifest.render(Manifest.build(cb_std)),
           "run mix composer.cookbook.manifest"
  end

  test "lint passes on cb_std" do
    {:ok, cookbooks} = Discovery.cookbooks(apps: [])
    cb_std = Cookbook.from_module(Composer.CbStd)

    assert %{diagnostics: []} = Lint.run(cb_std, cookbooks, File.cwd!())
  end

  test "lint fails on a stale or missing manifest, missing tests and bad requires", %{
    tmp_dir: dir
  } do
    {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book])
    fake = Cookbook.from_module(Composer.FakeBook)

    errors = messages(Lint.run(fake, cookbooks, dir))

    assert Enum.any?(errors, &(&1 =~ "manifest.exs is missing"))

    assert Enum.any?(
             errors,
             &(&1 =~ "fake_book:hello: no test. Add test/composer/fake_book/steps/hello_test.exs")
           )

    # A stale manifest: point the cookbook at a copy with an old manifest.
    copy = Path.join(dir, "fake_book")
    File.cp_r!(Cookbook.source_dir(fake), copy)

    File.write!(
      Path.join(copy, "manifest.exs"),
      Manifest.render(%{Manifest.build(fake) | steps: []})
    )

    errors = messages(Lint.run(%{fake | source_dir: copy}, cookbooks, dir))
    assert Enum.any?(errors, &(&1 =~ "manifest.exs is out of date"))

    # other_book's shared recipe uses fake_book/main/base, which only resolves when
    # fake_book is installed.
    other = Cookbook.from_module(Composer.OtherBook)
    {:ok, without_fake} = Discovery.cookbooks(apps: [:other_book])
    errors = messages(Lint.run(other, without_fake, dir))
    assert Enum.any?(errors, &(&1 =~ "names the cookbook \"fake_book\", which is not installed"))
  end

  test "the completion index lists step and recipe ids, read from manifests or metadata", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "recipes"))

    File.write!(
      Path.join(dir, "recipes/mine.exs"),
      "[a: [shortdoc: \"My recipe\\nMore\", steps: []], b: [shortdoc: \"B\", steps: []]]\n"
    )

    # A chapter that fails to load still lists its ids, with no shortdoc.
    File.write!(Path.join(dir, "recipes/broken.exs"), "[x: raise(\"boom\")]\n")

    cookbooks = discover(dir, [:fake_book, :other_book])

    lines = Index.lines(cookbooks)
    assert "step\tcb_std:echo\tPrints a message to stdout" in lines
    assert "step\tfake_book:ash:postgres\tAdds AshPostgres" in lines
    assert "recipe\tfake_book/nested/extra\tExtra steps" in lines
    assert "recipe\tmine/mine/a\tMy recipe" in lines
    assert "recipe\tmine/broken/x\t" in lines
    assert "chapter\tmine/mine/\t2 recipes" in lines
    assert "chapter\tfake_book/main/\t2 recipes" in lines
    assert "group\tcb_std:completions:\t2 steps" in lines
    assert "group\tother_book:cluster:\t3 steps" in lines
    assert "group\tother_book:cluster:gigalixir:\t1 step" in lines
    assert "group\tfake_book:ash:\t1 step" in lines
    assert "cookbook\tmine\tTest recipes in #{dir}" in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "cookbook\tfake_book\t"))

    path = Path.join(dir, "_build/composer/index")
    Index.write(cookbooks, path)
    assert File.read!(path) == Enum.map_join(lines, &(&1 <> "\n"))
  end

  test "the index has dir lines for directories under recipes/, and a self line" do
    {:ok, cookbooks} = Discovery.cookbooks(apps: [:nested_book])
    lines = Index.lines(cookbooks)

    assert "dir\tnested_book/ash/\t1 chapter, 1 directory" in lines
    assert "dir\tnested_book/ash/ui/\t1 chapter, 1 directory" in lines
    assert "dir\tnested_book/ash/ui/tailwind/\t1 chapter, 0 directories" in lines
    assert "chapter\tnested_book/ash/ui/tailwind/\t2 recipes" in lines
    assert "recipe\tnested_book/ash/ui/tailwind/forms/inputs\tForm inputs" in lines
    # Run from composer, whose own cookbook is cb_std.
    assert "self\tcb_std\t" in lines
  end

  defp messages(result), do: for(%{severity: :error} = d <- result.diagnostics, do: d.message)
end
