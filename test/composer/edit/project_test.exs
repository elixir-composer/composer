defmodule Composer.Edit.ProjectTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Composer.Edit.Project

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp gitignore(content), do: test_project(files: %{".gitignore" => content})

  describe "gitignore/3" do
    test "appends a missing entry" do
      assert gitignore("/_build/\n/deps/\n")
             |> Project.gitignore(".expert/")
             |> content(".gitignore") == "/_build/\n/deps/\n.expert/\n"
    end

    test "creates a missing .gitignore" do
      igniter = test_project() |> Igniter.rm(".gitignore") |> apply_igniter!()

      assert igniter |> Project.gitignore(".expert/") |> content(".gitignore") == ".expert/\n"
    end

    test "is idempotent" do
      igniter = gitignore("/deps/\n") |> Project.gitignore(".expert/", comment: "Expert")
      second = igniter |> apply_igniter!() |> Project.gitignore(".expert/", comment: "Expert")

      assert_unchanged(second, ".gitignore")
      assert second.warnings == []
    end

    test "normalises a variant entry in place rather than doubling it" do
      for variant <- [".expert", "/.expert", "/.expert/", ".expert/*"] do
        assert gitignore("/deps/\n#{variant}\n")
               |> Project.gitignore(".expert/")
               |> content(".gitignore") == "/deps/\n.expert/\n"
      end
    end

    test "does not match a longer name" do
      assert gitignore(".env.local\n")
             |> Project.gitignore(".env")
             |> content(".gitignore") == ".env.local\n.env\n"
    end

    test "adds a comment above a new entry, after a blank line" do
      assert gitignore("/deps/")
             |> Project.gitignore(".env", comment: "Environment variables")
             |> content(".gitignore") == "/deps/\n\n# Environment variables\n.env\n"
    end

    test "adds no comment above an entry that is already there" do
      gitignore("/deps/\n.env\n")
      |> Project.gitignore(".env", comment: "Environment variables")
      |> assert_unchanged(".gitignore")
    end

    test "state: :absent removes every variant" do
      assert gitignore(".expert\n/deps/\n/.expert/*\n")
             |> Project.gitignore(".expert/", state: :absent)
             |> content(".gitignore") == "/deps/\n"
    end
  end
end
