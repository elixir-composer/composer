defmodule Mix.Tasks.Composer.HelpTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "mix composer lists the composer.* tasks, but not itself" do
    output = capture_io(fn -> Mix.Tasks.Composer.run([]) end)

    assert output =~ "mix composer.recipe.run"
    assert output =~ "# Lists steps"
    refute output =~ ~r/^mix composer\s+#/m
    refute output =~ "composer.step.help"
  end

  for task <- ~w(composer.gen.recipe composer.gen.step
                 composer.recipe.edit composer.recipe.run composer.recipe.show
                 composer.step.edit composer.step.find composer.step.run
                 composer.step.show) do
    test "#{task} with no arguments prints its help" do
      output = capture_io(fn -> Mix.Task.rerun(unquote(task), []) end)
      assert output =~ "mix #{unquote(task)}"
    end
  end

  test "a missing argument among options still prints the help" do
    output = capture_io(fn -> Mix.Task.rerun("composer.gen.recipe", ["--dry-run"]) end)
    assert output =~ "mix composer.gen.recipe"
  end
end
