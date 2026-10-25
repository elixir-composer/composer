defmodule ComposerNew.RefTest do
  use ExUnit.Case, async: true

  alias ComposerNew.Ref

  doctest Ref

  @env %{cwd: "/work", home: "/home/me"}

  {fixture, _binding} = Code.eval_file(Path.expand("../fixtures/refs.exs", __DIR__))
  @fixture fixture

  @fields [:kind, :scope, :cookbook, :up, :segments, :source]

  test "parses every address in the shared fixture" do
    for entry <- @fixture do
      {string, expected} =
        case entry do
          {string, _expected, :composer} -> {string, :error}
          {string, expected, :archive} -> {string, expected}
          {string, expected} -> {string, expected}
        end

      case {expected, Ref.parse_address(string)} do
        {{:ok, fields}, {:ok, parsed}} ->
          assert Map.take(parsed, @fields) == fields, "#{string} parsed as #{inspect(parsed)}"

        {:error, {:error, message}} ->
          assert message =~ "Invalid reference #{inspect(string)}"

        {expected, got} ->
          flunk("#{string}: expected #{inspect(expected)}, got #{inspect(got)}")
      end
    end
  end

  test "keeps the spec as written" do
    assert {:ok, %{spec: "path:../cb-lab"}} = Ref.parse("cb-lab/lv/base@path:../cb-lab")
    assert {:ok, %{spec: nil}} = Ref.parse("cb_lab/lv/base")
    assert Ref.recipe(elem(Ref.parse("cb_lab/ash/ui/base@0.3"), 1)) == "cb_lab/ash/ui/base"
  end

  describe "archive rules" do
    test "accepts a qualified recipe with a source" do
      assert {:ok, %{cookbook: "cb_lab", segments: ["lv", "base"], source: [github: _, ref: _]}} =
               Ref.parse("cb_lab/lv/base@github:elixir-composer/cb_lab@v0.3.0")
    end

    test "rejects root, relative and search addresses" do
      for {address, why} <- [
            {"/lv/base", "a cookbook-root address has no cookbook"},
            {"./base", "a relative address has no cookbook"},
            {"base", "a bare name has no cookbook"}
          ] do
        assert {:error, message} = Ref.parse(address)
        assert message =~ why
        assert message =~ "cb_lab/lv/base@"
      end
    end

    test "rejects steps, and hex: which names a package" do
      assert {:error, message} = Ref.parse("cb_lab:lv:base")
      assert message =~ "that is a step"

      assert {:error, message} = Ref.parse("hex:oban")
      assert message =~ "hex: names a package, not a recipe"
      assert {:error, _} = Ref.parse("hex:oban@2.0.0")
    end

    test "rejects the old cookbook:chapter/recipe form" do
      assert {:error, message} = Ref.parse("cb_lab:lv/base")
      assert message =~ ~s("cb_lab/lv/base")
    end

    test "cb_std/ takes no source" do
      assert {:ok, %{cookbook: "cb_std", source: []}} = Ref.parse("cb_std/debug/echo")
      assert {:error, message} = Ref.parse("cb_std/debug/echo@0.3")
      assert message =~ "cb_std ships with composer; drop the @source"
    end
  end

  test "parse_source/1 takes a bare source" do
    assert Ref.parse_source("path:../composer") == {:ok, [path: "../composer"]}
    assert Ref.parse_source("github:o/r@main") == {:ok, [github: "o/r", ref: "main"]}
    assert Ref.parse_source("~> 0.3") == {:ok, [version: "~> 0.3"]}
    assert Ref.parse_source("0.3") == {:ok, [version: "~> 0.3"]}

    assert {:error, "Invalid source \"svn:x\": unknown source svn:" <> _} =
             Ref.parse_source("svn:x")
  end

  describe "install_spec/3 and expand_package/2" do
    test "make path: sources absolute" do
      assert Ref.install_spec("cb", "path:../cb", @env) == "cb@path:/cb"
      assert Ref.install_spec("cb", "path:cb", @env) == "cb@path:/work/cb"
      assert Ref.install_spec("cb", "path:~/src/cb", @env) == "cb@path:/home/me/src/cb"
      assert Ref.install_spec("cb", "path:/abs/cb", @env) == "cb@path:/abs/cb"
    end

    test "keep other sources as written" do
      assert Ref.install_spec("cb", nil, @env) == "cb"
      assert Ref.install_spec("cb", "~> 0.3", @env) == "cb@~> 0.3"
      assert Ref.install_spec("cb", "github:o/r@v1", @env) == "cb@github:o/r@v1"
    end

    test "split a whole package spec" do
      assert Ref.expand_package("astral@path:~/src/Fork/astral", @env) ==
               "astral@path:/home/me/src/Fork/astral"

      assert Ref.expand_package("oban", @env) == "oban"
      assert Ref.expand_package("oban@2.0", @env) == "oban@2.0"
    end
  end
end
