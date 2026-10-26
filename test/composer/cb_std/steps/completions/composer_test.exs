defmodule Composer.CbStd.Steps.Completions.ComposerTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Composer.CbStd.Steps.Completions
  alias Composer.CbStd.Steps.Completions.Composer, as: Step

  @moduletag :tmp_dir

  # The scripts themselves are tested in composer. The step writes outside
  # the project, so its tests install to tmp paths through install/3.

  test "is experimental" do
    meta = Completions.Composer.__composer_step__()

    assert meta.stability == :experimental
    assert meta.action == :gen
  end

  test "each shell's script is a template of the step, shipped in lib/" do
    assert "lib" in Mix.Project.config()[:package][:files]

    for shell <- Step.shells() do
      assert Step.script!(shell) =~ ~r/completion for composer's mix tasks/
      assert "~/" <> _ = Step.targets()[shell].path
    end

    assert_raise FunctionClauseError, fn -> Step.script!("nope") end
  end

  test "writes composer's script for each shell", %{tmp_dir: dir} do
    for shell <- Step.shells() do
      path = Path.join([dir, shell, Path.basename(Step.targets()[shell].path)])
      File.mkdir_p!(Path.dirname(path))

      igniter = Completions.Composer.install(test_project(), shell, path)

      assert igniter.issues == []
      assert igniter.notices == ["composer completions are installed in #{path}"]
      assert File.read!(path) == Step.script!(shell)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o755
    end
  end

  test "a second run is up to date", %{tmp_dir: dir} do
    path = Path.join(dir, "mix_composer.bash")
    Completions.Composer.install(test_project(), "bash", path)

    igniter = Completions.Composer.install(test_project(), "bash", path)
    assert igniter.notices == ["#{path} is up to date"]
  end

  test "an unknown --shell is an issue" do
    igniter = Igniter.compose_task(test_project(), Completions.Composer, ["--shell", "nope"])

    assert [issue] = igniter.issues
    assert issue =~ ~s(unknown --shell "nope")
  end

  test "bash needs an existing directory", %{tmp_dir: dir} do
    path = Path.join([dir, "missing", "mix_composer.bash"])
    igniter = Completions.Composer.install(test_project(), "bash", path)

    assert [issue] = igniter.issues
    assert issue =~ "missing does not exist"
    refute File.exists?(Path.dirname(path))
  end

  test "--path installs elsewhere, creating its directory", %{tmp_dir: dir} do
    path = Path.join([dir, "dotfiles", "composer.bash"])

    igniter =
      Igniter.compose_task(test_project(), Completions.Composer, [
        "--shell",
        "bash",
        "--path",
        path
      ])

    assert igniter.issues == []
    assert File.read!(path) == Step.script!("bash")
  end

  test "zsh and fish create their directory", %{tmp_dir: dir} do
    for shell <- ~w(zsh fish) do
      path = Path.join([dir, shell, "nested", "file"])
      igniter = Completions.Composer.install(test_project(), shell, path)

      assert igniter.issues == []
      assert File.read!(path) == Step.script!(shell)
    end
  end
end
