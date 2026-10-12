defmodule Mix.Tasks.Composer.Cookbook.LintTest do
  # Sets the :composer application env and swaps the Mix shell.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "recipes"))
    broken = Path.join(dir, "recipes/broken.exs")
    clean = Path.join(dir, "recipes/clean.exs")
    File.write!(broken, ~s|[\n  a: [shortdoc: "x", steps: ["credoo", "core:nope"]]\n]\n|)
    File.write!(clean, ~s|[\n  b: [shortdoc: "x", steps: ["core:setup/gitignore"]]\n]\n|)

    Application.put_env(:composer, :discovery, modules: [Composer.FakeBook])
    on_exit(fn -> Application.delete_env(:composer, :discovery) end)
    %{config: dir, broken: broken, clean: clean}
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

  test "json: stdout is only the payload, and errors exit with status 1", %{
    config: config,
    broken: broken
  } do
    {output, result} = lint(["--local", "-c", config, "--format", "json"])

    assert result == {:exit, {:shutdown, 1}}
    assert [typo, missing] = Jason.decode!(output)
    assert %{"code" => "typo", "file" => ^broken, "line" => 2, "column" => 30} = typo
    assert %{"code" => "missing_step", "column" => 40} = missing
    # The shell is restored afterwards.
    assert Mix.shell() == Mix.Shell.IO
  end

  test "compact: one parseable line per diagnostic", %{config: config, broken: broken} do
    {output, {:exit, {:shutdown, 1}}} = lint(["--local", "-c", config, "--format", "compact"])

    assert [first, second] = String.split(output, "\n", trim: true)

    assert first =~
             ~r/^#{Regex.escape(broken)}:2:30: error: In recipe local:broken\/a: .* \[typo\]$/

    assert second =~ ~r/^#{Regex.escape(broken)}:2:40: error: .* \[missing_step\]$/
  end

  test "github: annotations", %{config: config} do
    {output, {:exit, {:shutdown, 1}}} = lint(["--local", "-c", config, "--format", "github"])

    assert output =~
             ~r/^::error file=.*broken.exs,line=2,col=30,endLine=2,endColumn=38,title=composer lint \[typo\]::/m
  end

  test "text: located problems, raising on errors", %{config: config} do
    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Mix.Tasks.Composer.Cookbook.Lint.run(["--local", "-c", config]) end)
      end

    assert error.message =~ "have 2 problem(s)"

    assert error.message =~
             ~r/\* \S*broken.exs:2:30: In recipe local:broken\/a: no step matches "credoo"/
  end

  test "--file: only that file, even when another one is broken", %{
    config: config,
    broken: broken,
    clean: clean
  } do
    assert {"", :ok} = lint(["-c", config, "--format", "compact", "--file", clean])

    {output, {:exit, {:shutdown, 1}}} =
      lint(["-c", config, "--format", "compact", "--file", broken])

    assert length(String.split(output, "\n", trim: true)) == 2

    {output, :ok} = lint(["-c", config, "--file", clean])
    assert output =~ "clean.exs is valid."
  end

  test "--file: a file of no cookbook, or --local on a cookbook's file, is an error", %{
    config: config
  } do
    assert_raise Mix.Error, ~r/is not a recipe group of your local config/, fn ->
      lint(["-c", config, "--format", "compact", "--file", "mix.exs"])
    end

    fake = Composer.Cookbook.source_dir(Composer.Cookbook.from_module(Composer.FakeBook))

    assert_raise Mix.Error, ~r/belongs to the cookbook fake_book/, fn ->
      lint(["-c", config, "--local", "--file", Path.join(fake, "recipes/main.exs")])
    end
  end

  test "an unknown format is an error", %{config: config} do
    assert_raise Mix.Error, ~r/Unknown --format yaml/, fn ->
      lint(["--local", "-c", config, "--format", "yaml"])
    end
  end
end
