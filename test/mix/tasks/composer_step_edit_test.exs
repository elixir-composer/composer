defmodule Mix.Tasks.Composer.StepEditTest do
  # Sets the :composer application env and COMPOSER_EDITOR.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  @hello Path.expand(
           "../../support/cookbooks/fake_book/lib/composer/fake_book/steps/hello.ex",
           __DIR__
         )

  setup do
    Application.put_env(:composer, :discovery, modules: [Composer.FakeBook])

    on_exit(fn ->
      Application.delete_env(:composer, :discovery)
      System.delete_env("COMPOSER_EDITOR")
    end)
  end

  defp run(argv) do
    Mix.Task.reenable("composer.step.edit")
    capture_io(fn -> Mix.Task.run("composer.step.edit", argv) end)
  end

  test "--print shows the step's source file and its `use Composer.Step` line" do
    assert run(["--print", "fake_book:hello"]) == "#{@hello}:2\n"
    assert run(["--print", "hello"]) == "#{@hello}:2\n"
  end

  test "opens the editor from COMPOSER_EDITOR", %{tmp_dir: dir} do
    out = Path.join(dir, "opened")
    System.put_env("COMPOSER_EDITOR", "echo __FILE__:__LINE__ > '#{out}'")
    run(["fake_book:hello"])
    assert File.read!(out) == "#{@hello}:2\n"
  end

  test "raises on a failing editor" do
    System.put_env("COMPOSER_EDITOR", "false")

    assert_raise Mix.Error, ~r/Editor exited with status 1/, fn ->
      run(["fake_book:hello"])
    end
  end

  test "raises on a Hex package" do
    assert_raise Mix.Error, ~r/Hex package oban, not a step/, fn -> run(["--print", "oban"]) end
  end

  test "raises on an unknown step" do
    assert_raise Mix.Error, fn -> run(["--print", "fake_book:nope"]) end
  end
end
