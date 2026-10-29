defmodule Composer.HelpersTest do
  # Composer.Helpers is deprecated: each function delegates to its new home
  # in Composer.Edit, and must give the same result.
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Composer.Edit.{Files, Project, Util}
  alias Composer.Helpers

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  test "the naming delegates match Composer.Edit.Project" do
    project = test_project()

    assert Helpers.app_module(project) == Project.app_module(project)
    assert Helpers.app_web_module(project) == Project.app_web_module(project)
    assert Helpers.repo(project) == Project.repo(project)
    assert Helpers.repo(project) == Test.Repo
  end

  test "update_file_content/3 matches Files.update/3" do
    project = test_project(files: %{"notes.txt" => "one\n"})
    upcase = &String.upcase/1

    assert content(Helpers.update_file_content(project, "notes.txt", upcase), "notes.txt") ==
             content(Files.update(project, "notes.txt", upcase), "notes.txt")
  end

  test "update_file_checked/4 matches Files.update_checked/4, changed or not" do
    project = test_project(files: %{"notes.txt" => "one\n"})
    upcase = &String.upcase/1

    assert content(Helpers.update_file_checked(project, "notes.txt", upcase, "w"), "notes.txt") ==
             "ONE\n"

    unchanged = &Function.identity/1

    assert Helpers.update_file_checked(project, "notes.txt", unchanged, "nothing changed").warnings ==
             Files.update_checked(project, "notes.txt", unchanged, "nothing changed").warnings

    assert Helpers.update_file_checked(project, "missing.txt", upcase, "w").warnings ==
             ["missing.txt not found — w"]
  end

  test "create_unless_exists/3 matches Files.create_unless_exists/3" do
    project = test_project(files: %{"notes.txt" => "one\n"})

    for fun <- [&Helpers.create_unless_exists/3, &Files.create_unless_exists/3] do
      igniter = project |> fun.("notes.txt", "two\n") |> fun.("new.txt", "new\n")
      assert content(igniter, "notes.txt") == "one\n"
      assert content(igniter, "new.txt") == "new\n"
    end
  end

  test "gen_migration/4 delegates to Util.gen_migration/4" do
    paths = fn igniter ->
      igniter.rewrite
      |> Rewrite.paths()
      |> Enum.filter(&String.contains?(&1, "migrations/"))
    end

    old = Helpers.gen_migration(phx_test_project(), Test.Repo, "add_one", body: "")
    new = Util.gen_migration(phx_test_project(), Test.Repo, "add_one", body: "")

    assert [old_path] = paths.(old)
    assert [new_path] = paths.(new)
    assert String.ends_with?(old_path, "_add_one.exs")
    assert String.ends_with?(new_path, "_add_one.exs")
  end
end
