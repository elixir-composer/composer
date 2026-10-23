defmodule Composer.LSP.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Composer.Lint
  import Composer.Test.Cookbooks
  alias Composer.LSP.Diagnostics

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    cookbooks = discover(dir, [:fake_book, :other_book])
    File.mkdir_p!(Path.join(dir, "recipes"))

    write = fn name, source -> File.write!(Path.join([dir, "recipes", name]), source) end
    write.("ash.exs", ~s|[\n  base: [shortdoc: "x", steps: ["credoo"]]\n]\n|)
    write.("app.exs", ~s|[\n  full: [shortdoc: "x", steps: [{:use, "mine:ash/base"}]]\n]\n|)
    write.("other.exs", ~s|[\n  ok: [shortdoc: "x", steps: ["core:setup/gitignore"]]\n]\n|)

    args = %{cookbooks: cookbooks, root: File.cwd!(), known_dependents: []}
    %{args: args, ash: Path.join(dir, "recipes/ash.exs"), app: Path.join(dir, "recipes/app.exs")}
  end

  test "the saved file and the files including it, as lint gives them", %{
    args: args,
    ash: ash,
    app: app
  } do
    assert {:ok, results, [^app]} = Diagnostics.run(ash, args)
    assert Map.keys(results) |> Enum.sort() == Enum.sort([ash, app])
    assert [%{code: :typo}] = results[ash]
    assert [%{code: :include_problems}] = results[app]

    # The saved file's own diagnostics are lint --file's.
    assert results[ash] ==
             Lint.files(args.cookbooks, [ash], root: args.root)[ash]
  end

  test "known dependents are linted even when no longer found", %{
    tmp_dir: dir,
    args: args,
    ash: ash
  } do
    other = Path.join(dir, "recipes/other.exs")
    assert {:ok, results, dependents} = Diagnostics.run(ash, %{args | known_dependents: [other]})
    assert other in dependents
    assert results[other] == []
  end

  test "a file that is not a recipe group is ignored", %{args: args} do
    assert Diagnostics.run(Path.expand("mix.exs"), args) == :ignore
  end
end
