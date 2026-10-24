defmodule Composer.CbStd.Steps.GitignoreTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "appends to the default project .gitignore" do
    igniter =
      test_project()
      |> Igniter.compose_task(Composer.CbStd.Steps.Setup.Gitignore)

    assert diff(igniter, only: ".gitignore") =~ ".expert/"
  end

  test "appends to an existing .gitignore" do
    igniter =
      test_project(files: %{".gitignore" => "/_build/\n/deps/\n"})
      |> Igniter.compose_task(Composer.CbStd.Steps.Setup.Gitignore)

    assert diff(igniter, only: ".gitignore") =~ ".expert/"
  end

  test "is idempotent when .expert is already ignored" do
    test_project(files: %{".gitignore" => ".expert/\n"})
    |> Igniter.compose_task(Composer.CbStd.Steps.Setup.Gitignore)
    |> assert_unchanged(".gitignore")
  end
end
