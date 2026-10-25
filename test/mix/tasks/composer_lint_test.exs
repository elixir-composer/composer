defmodule Mix.Tasks.Composer.Cookbook.LintTest do
  # Sets the :composer application env and swaps the Mix shell.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "recipes"))
    broken = Path.join(dir, "recipes/broken.exs")
    clean = Path.join(dir, "recipes/clean.exs")
    File.write!(broken, ~s|[\n  a: [shortdoc: "x", steps: ["credoo", "cb_std:nope"]]\n]\n|)
    File.write!(clean, ~s|[\n  b: [shortdoc: "x", steps: ["cb_std:setup:gitignore"]]\n]\n|)

    Application.put_env(:composer, :discovery,
      modules: [Composer.FakeBook],
      cookbooks: [code_cookbook(dir)]
    )

    on_exit(fn -> Application.delete_env(:composer, :discovery) end)
    %{broken: broken, clean: clean}
  end

  # Runs the task, returning its stdout and :ok or the exit reason.
  defp lint(argv) do
    Mix.Task.reenable("composer.cookbook.lint")
    parent = self()

    output =
      capture_io(fn ->
        result =
          try do
            Mix.Task.run("composer.cookbook.lint", argv)
            :ok
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {:result, result})
      end)

    assert_received {:result, result}
    {output, result}
  end

  test "json: stdout is only the payload, and errors exit with status 1", %{broken: broken} do
    {output, result} = lint(["--file", broken, "--format", "json"])

    assert result == {:exit, {:shutdown, 1}}
    assert [typo, missing] = Jason.decode!(output)
    assert %{"code" => "bare_word", "file" => ^broken, "line" => 2, "column" => 30} = typo
    assert %{"code" => "missing_step", "column" => 40} = missing
    # The shell is restored afterwards.
    assert Mix.shell() == Mix.Shell.IO
  end

  test "compact: one parseable line per diagnostic", %{broken: broken} do
    {output, {:exit, {:shutdown, 1}}} = lint(["--file", broken, "--format", "compact"])

    assert [first, second] = String.split(output, "\n", trim: true)

    assert first =~
             ~r/^#{Regex.escape(broken)}:2:30: error: In recipe mine\/broken\/a: .* \[bare_word\]$/

    assert second =~ ~r/^#{Regex.escape(broken)}:2:40: error: .* \[missing_step\]$/
  end

  test "github: annotations", %{broken: broken} do
    {output, {:exit, {:shutdown, 1}}} = lint(["--file", broken, "--format", "github"])

    assert output =~
             ~r/^::error file=.*broken.exs,line=2,col=30,endLine=2,endColumn=38,title=composer lint \[bare_word\]::/m
  end

  test "text: located problems, raising on errors", %{broken: broken} do
    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Mix.Tasks.Composer.Cookbook.Lint.run(["--file", broken]) end)
      end

    assert error.message =~ "has 2 problem(s)"

    assert error.message =~
             ~r/\* \S*broken.exs:2:30: In recipe mine\/broken\/a: "credoo" is not an address/
  end

  test "--file: only that file, even when another one is broken", %{
    broken: broken,
    clean: clean
  } do
    assert {"", :ok} = lint(["--format", "compact", "--file", clean])

    {output, {:exit, {:shutdown, 1}}} =
      lint(["--format", "compact", "--file", broken])

    assert length(String.split(output, "\n", trim: true)) == 2

    {output, :ok} = lint(["--file", clean])
    assert output =~ "clean.exs is valid."
  end

  test "--file: a file of no cookbook is an error" do
    assert_raise Mix.Error, ~r/is not a chapter of an installed cookbook/, fn ->
      lint(["--format", "compact", "--file", "mix.exs"])
    end
  end

  test "an unknown format is an error", %{broken: broken} do
    assert_raise Mix.Error, ~r/Unknown --format yaml/, fn ->
      lint(["--file", broken, "--format", "yaml"])
    end
  end
end
