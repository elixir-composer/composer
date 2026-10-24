defmodule ComposerNew.DepTest do
  use ExUnit.Case, async: true

  alias ComposerNew.Dep

  doctest ComposerNew.Dep

  defp igniter!(string) do
    assert {:ok, dep} = Dep.parse(string)
    Dep.to_igniter(dep)
  end

  test "no source is the latest Hex release, left to Igniter" do
    assert igniter!("jason") == :latest
    assert igniter!("org/jason") == :latest
  end

  test "a version requirement is kept as written" do
    assert igniter!("composer@~> 0.3") == {:composer, "~> 0.3"}
    assert igniter!("composer@~> 0.3.1") == {:composer, "~> 0.3.1"}
    assert igniter!("jason@>= 1.4.0") == {:jason, ">= 1.4.0"}
  end

  test "a version follows Igniter's rule" do
    assert igniter!("jason@1.4.1") == {:jason, "== 1.4.1"}
    assert igniter!("jason@1.4") == {:jason, "~> 1.0"}
    assert igniter!("composer@0.3") == {:composer, "~> 0.3"}
  end

  test "git, github and path sources override" do
    assert igniter!("cb@github:o/cb") == {:cb, github: "o/cb", override: true}
    assert igniter!("cb@github:o/cb@v1") == {:cb, github: "o/cb", ref: "v1", override: true}
    assert igniter!("cb@path:/src/cb") == {:cb, path: "/src/cb", override: true}

    # igniter.install would split this URL at its @.
    assert igniter!("cb@git:git@github.com:o/cb.git") ==
             {:cb, git: "git@github.com:o/cb.git", override: true}
  end

  test "an organization or a repository" do
    assert igniter!("acme/secret@~> 1.0") == {:secret, "~> 1.0", organization: "acme"}
    assert igniter!("mirror.secret@~> 1.0") == {:secret, "~> 1.0", repo: "mirror"}
  end

  test "errors" do
    assert {:error, "Invalid package \"Jason\": package names" <> _} = Dep.parse("Jason")

    assert {:error, "Invalid package \"jason@svn:x\": Invalid source" <> _} =
             Dep.parse("jason@svn:x")

    assert {:error, "Invalid package \"jason@\": " <> _} = Dep.parse("jason@")
    assert {:error, _} = Dep.parse("jason@not a version")
  end
end
