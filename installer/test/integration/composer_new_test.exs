defmodule ComposerNew.IntegrationTest do
  # Builds and installs the archive into a private archives directory, then
  # generates real apps with it from composer's test/fixtures/fake_dep
  # cookbook. Needs the network (Hex) and the igniter_new archive.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  @installer Path.expand("../..", __DIR__)
  @composer Path.dirname(@installer)
  @fixture Path.join(@composer, "test/fixtures/fake_dep")
  @cookbook ["--cookbook", "fake_dep@path:#{@fixture}"]
  @recipe ["--recipe", "fake_dep/main/default"]

  setup_all do
    archives =
      Path.join(System.tmp_dir!(), "composer_new_archives_#{System.unique_integer([:positive])}")

    File.mkdir_p!(archives)
    on_exit(fn -> File.rm_rf!(archives) end)

    # The developer's archives (hex, igniter_new, ...) stay untouched: copy
    # them, then install this build next to them.
    for dir <- File.ls!(Mix.path_for(:archives)), not String.starts_with?(dir, "composer_new") do
      File.cp_r!(Path.join(Mix.path_for(:archives), dir), Path.join(archives, dir))
    end

    ez = Path.join(archives, "composer_new.ez")
    {_, 0} = System.cmd("mix", ["archive.build", "-o", ez], cd: @installer, env: env(archives))
    {_, 0} = System.cmd("mix", ["archive.install", ez, "--force"], env: env(archives))
    File.rm!(ez)

    %{archives: archives}
  end

  # The children run in dev, as they would from a terminal, not in the
  # test env this test runs in.
  defp env(archives), do: [{"MIX_ARCHIVES", archives}, {"MIX_ENV", nil}]

  defp composer_new(args, dir, archives) do
    System.cmd("mix", ["composer.new" | args],
      cd: dir,
      env: env(archives),
      stderr_to_stdout: true
    )
  end

  defp log(app) do
    {out, 0} = System.cmd("git", ["log", "--reverse", "--format=%s"], cd: app)
    String.split(out, "\n", trim: true)
  end

  test "creates an app, records the command line and runs the recipe", %{
    tmp_dir: dir,
    archives: archives
  } do
    args = ["tmp_app" | @cookbook] ++ @recipe ++ ["--composer", "path:#{@composer}"]
    {out, status} = composer_new(args, dir, archives)
    assert status == 0, out

    app = Path.join(dir, "tmp_app")
    assert [first, second] = log(app)

    assert first ==
             "mix composer.new tmp_app --cookbook fake_dep@path:#{@fixture} " <>
               "--recipe fake_dep/main/default --composer path:#{@composer}"

    assert second =~ "fake_dep/main/default"
    assert File.exists?(Path.join(app, "hi.txt"))

    {out, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: app,
        env: env(archives),
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  test "--dry-run prints the commands and creates nothing", %{tmp_dir: dir, archives: archives} do
    {out, 0} = composer_new(["dry_app" | @cookbook] ++ @recipe ++ ["--dry-run"], dir, archives)
    assert out =~ "mix igniter.new dry_app --no-git --yes"
    assert out =~ "mix composer.recipe.run fake_dep/main/default"
    assert out =~ "Dry run: nothing was run."
    refute File.exists?(Path.join(dir, "dry_app"))
  end

  test "a bad recipe flag leaves the generation commit and a retry hint", %{
    tmp_dir: dir,
    archives: archives
  } do
    args =
      ["bad_app" | @cookbook] ++
        @recipe ++ ["--recipe-args=--no-such-flag", "--composer", "path:#{@composer}"]

    {out, status} = composer_new(args, dir, archives)
    assert status != 0

    app = Path.join(dir, "bad_app")
    assert [only] = log(app)
    assert only =~ "mix composer.new bad_app"
    assert out =~ "is at its generation commit"

    assert out =~
             "cd #{app} && mix composer.recipe.run fake_dep/main/default --no-such-flag"
  end

  test "a recipe the cookbook doesn't have fails, after the generation commit", %{
    tmp_dir: dir,
    archives: archives
  } do
    args =
      ["nope_app" | @cookbook] ++
        ["--recipe", "fake_dep/main/no_such_recipe", "--composer", "path:#{@composer}"]

    {out, status} = composer_new(args, dir, archives)
    assert status != 0
    assert out =~ "no_such_recipe"
    assert out =~ "is at its generation commit"
    assert [_only] = log(Path.join(dir, "nope_app"))
  end

  test "the default composer comes from Hex, and requirements are kept as written", %{
    tmp_dir: dir,
    archives: archives
  } do
    {out, status} = composer_new(["hex_app", "--install", "jason@~> 1.4"], dir, archives)
    assert status == 0, out

    mix_exs = File.read!(Path.join([dir, "hex_app", "mix.exs"]))
    requirement = ComposerNew.Plan.default_composer(Mix.Project.config()[:version])
    assert mix_exs =~ ~s({:composer, "#{requirement}", only: [:dev, :test]})
    assert mix_exs =~ ~s({:jason, "~> 1.4"})
    assert [_only] = log(Path.join(dir, "hex_app"))
  end
end
