defmodule Mix.Tasks.Composer.RecipeEditTest do
  # Sets the :composer application env and COMPOSER_EDITOR.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "recipes"))

    File.write!(Path.join(dir, "recipes/phx.exs"), """
    [
      first: [shortdoc: "First", steps: []],

      second: [
        shortdoc: "Second",
        steps: [{:use, "no_such_recipe"}]
      ]
    ]
    """)

    Application.put_env(:composer, :discovery,
      modules: [Composer.FakeBook],
      cookbooks: [code_cookbook(dir)]
    )

    on_exit(fn ->
      Application.delete_env(:composer, :discovery)
      System.delete_env("COMPOSER_EDITOR")
    end)

    %{chapter: Path.join(dir, "recipes/phx.exs")}
  end

  defp run(argv) do
    Mix.Task.reenable("composer.recipe.edit")
    capture_io(fn -> Mix.Task.run("composer.recipe.edit", argv) end)
  end

  test "--print shows the chapter file and the recipe's line, even if it fails to load",
       %{chapter: chapter} do
    assert run(["--print", "mine:phx/first"]) == "#{chapter}:2\n"
    assert run(["--print", "phx/second"]) == "#{chapter}:4\n"
  end

  test "opens the editor from COMPOSER_EDITOR", %{chapter: chapter, tmp_dir: dir} do
    out = Path.join(dir, "opened")
    System.put_env("COMPOSER_EDITOR", "echo __FILE__:__LINE__ > '#{out}'")
    run(["phx/second"])
    assert File.read!(out) == "#{chapter}:4\n"
  end

  test "raises on a failing editor" do
    System.put_env("COMPOSER_EDITOR", "false")

    assert_raise Mix.Error, ~r/Editor exited with status 1/, fn ->
      run(["phx/first"])
    end
  end

  test "raises on an unknown recipe" do
    assert_raise Mix.Error, fn -> run(["--print", "phx/nope"]) end
  end
end
