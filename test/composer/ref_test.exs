defmodule Composer.RefTest do
  use ExUnit.Case, async: true

  alias Composer.Ref

  doctest Composer.Ref

  defp why(string) do
    assert {:error, {:invalid_ref, ^string, why}} = Ref.parse(string),
           "expected #{inspect(string)} to fail"

    why
  end

  describe "parse/1 errors" do
    test "mixed separators name both readings" do
      assert why("cb_std/ash:postgres") =~ ~s("cb_std/ash/postgres" or "cb_std:ash:postgres")
      assert why(":a/b") =~ "one separator"
    end

    test ". and .. only as a leading prefix" do
      for bad <- ["./a/../b", "a/./b", "/a/../b", "./../b"] do
        assert why(bad) =~ "may only begin an address"
      end

      assert why(".base") =~ "starts with ./ or ../"
    end

    test "relative steps are reserved" do
      for bad <- [".:dns", "..:aws:dns", "../..:x"] do
        assert why(bad) == "relative step references are not supported yet"
      end
    end

    test "hex is a step cookbook with one package" do
      assert why("hex/oban") =~ "hex is a step cookbook"
      assert why("hex:a:b") =~ "names one package"
    end

    test "an @ source only on hex:" do
      assert why("cb_std:x@1") =~ ~s("hex:x@1")
      assert why("ash@3.5") =~ ~s("hex:ash@3.5")
      assert why("cb_lab/lv/base@0.3") =~ "a recipe address takes no @ source"
    end

    test "invalid names and empty segments" do
      assert why("Cb/lv/base") =~ "cookbook names"
      assert why("cb/Lv/base") =~ ~s("Lv" is not a name)
      assert why("cb//base") =~ "empty segments"
      assert why("cb:") =~ "empty segments"
      assert why("") =~ "empty"
    end
  end

  test "to_string/1 writes canonical forms" do
    for string <- [
          "./base",
          "../../core",
          "/a/b",
          ":a:b",
          "cb/a/b",
          "cb:a:b",
          "hex:pkg@path:../pkg",
          "word"
        ] do
      assert Ref.to_string(Ref.parse!(string)) == string
    end

    assert Ref.to_string(Ref.parse!("hex:ash@3.5.0")) == "hex:ash@== 3.5.0"
    assert Ref.to_string(Ref.parse!("cb-x/a-b/c")) == "cb_x/a_b/c"
  end

  test "parse, write back and parse is stable for canonical addresses" do
    names = ["a", "ui", "x_1", "tailwind"]

    paths = for n <- 1..3, path <- paths(names, n), do: path

    addresses =
      for path <- paths, form <- forms(path), do: form

    assert length(addresses) > 100

    for address <- addresses do
      ref = Ref.parse!(address)
      assert Ref.to_string(ref) == address
      assert Ref.parse!(Ref.to_string(ref)) == ref
    end
  end

  defp paths(_names, 0), do: [[]]
  defp paths(names, n), do: for(name <- names, rest <- paths(names, n - 1), do: [name | rest])

  defp forms(segments) do
    recipe = Enum.join(segments, "/")
    step = Enum.join(segments, ":")

    ["cb/" <> recipe, "cb:" <> step, "/" <> recipe, ":" <> step, "./" <> recipe, "../" <> recipe] ++
      if(length(segments) == 1, do: [recipe, "hex:" <> recipe], else: [])
  end

  test "id/3 builds canonical ids from segments or an internal id" do
    assert Ref.id(:step, "cb_std", ["setup", "credo"]) == "cb_std:setup:credo"

    assert Ref.id(:step, "cb_std", "cluster/gigalixir/libcluster") ==
             "cb_std:cluster:gigalixir:libcluster"

    assert Ref.id(:recipe, "cb_std", "ash/ui/buttons") == "cb_std/ash/ui/buttons"
  end

  test "parse_stem/1" do
    assert Ref.parse_stem("cb_std/") == {:ok, %{kind: :recipe, cookbook: "cb_std", segments: []}}
    assert Ref.parse_stem("cb_std:") == {:ok, %{kind: :step, cookbook: "cb_std", segments: []}}

    assert Ref.parse_stem("cb_std:cluster:") ==
             {:ok, %{kind: :step, cookbook: "cb_std", segments: ["cluster"]}}

    assert Ref.parse_stem("/") == {:ok, %{kind: :recipe, cookbook: nil, segments: []}}
    assert Ref.parse_stem("/ash/") == {:ok, %{kind: :recipe, cookbook: nil, segments: ["ash"]}}

    for bad <- ["cb_std", "cb_std/ash", "./", "cb/a:", "hex/"] do
      assert {:error, {:invalid_ref, ^bad, _}} = Ref.parse_stem(bad), inspect(bad)
    end
  end

  test "parsing creates no atoms" do
    name = "zz_never_an_atom_#{System.unique_integer([:positive])}"
    Ref.parse("cb/#{name}/x")
    Ref.parse("hex:#{name}")
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
