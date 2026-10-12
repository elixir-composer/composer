defmodule Mix.Tasks.Composer.RecipeEditTest do
  # Sets the :composer application env and COMPOSER_EDITOR.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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

    Application.put_env(:composer, :discovery, modules: [Composer.FakeBook])

    on_exit(fn ->
      Application.delete_env(:composer, :discovery)
      System.delete_env("COMPOSER_EDITOR")
    end)

    %{config: dir, group: Path.join(dir, "recipes/phx.exs")}
  end

  defp run(argv) do
    Mix.Task.reenable("composer.recipe.edit")
    capture_io(fn -> Mix.Task.run("composer.recipe.edit", argv) end)
  end

  test "--print shows the group file and the recipe's line, even if it fails to load",
       %{config: config, group: group} do
    assert run(["-c", config, "--print", "local:phx/first"]) == "#{group}:2\n"
    assert run(["-c", config, "--print", "phx/second"]) == "#{group}:4\n"
  end

  test "opens the editor from COMPOSER_EDITOR", %{config: config, group: group, tmp_dir: dir} do
    out = Path.join(dir, "opened")
    System.put_env("COMPOSER_EDITOR", "echo __FILE__:__LINE__ > '#{out}'")
    run(["-c", config, "phx/second"])
    assert File.read!(out) == "#{group}:4\n"
  end

  test "raises on a failing editor", %{config: config} do
    System.put_env("COMPOSER_EDITOR", "false")

    assert_raise Mix.Error, ~r/Editor exited with status 1/, fn ->
      run(["-c", config, "phx/first"])
    end
  end

  test "raises on an unknown recipe", %{config: config} do
    assert_raise Mix.Error, fn -> run(["-c", config, "--print", "phx/nope"]) end
  end
end
