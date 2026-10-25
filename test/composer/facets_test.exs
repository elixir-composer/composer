defmodule Composer.FacetsTest do
  use ExUnit.Case, async: true

  alias Composer.Facets

  test "normalizes options, defaulting list facets to [] and wrapping bare atoms" do
    assert {:ok, facets, []} =
             Facets.validate(summary: "x", action: :add, capability: :devtools, tags: [:a, "b"])

    assert facets.capability == [:devtools]
    assert facets.tags == ["a", "b"]
    assert facets.frameworks == []
    assert facets.phase == nil
  end

  test "unknown facet values are warnings" do
    assert {:ok, _facets, [warning]} = Facets.validate(action: :frobnicate)
    assert warning =~ "unknown action value :frobnicate"
  end

  test "wrong types, unknown options and bad requires are errors" do
    assert {:error, "tags: expected a list" <> _} = Facets.validate(tags: "x")
    assert {:error, "summary: expected a string" <> _} = Facets.validate(summary: :x)
    assert {:error, "unknown step option(s) :colour" <> _} = Facets.validate(colour: :red)
    assert {:error, "invalid requires entry" <> _} = Facets.validate(requires: [{:executable, 1}])

    assert {:ok, _, []} =
             Facets.validate(
               requires: [
                 "cb_std:setup:credo",
                 {:executable, "bun"},
                 {:package, :phoenix, "~> 1.8"}
               ]
             )
  end

  test "requires takes qualified, root and hex: step addresses" do
    for ok <- ["cb_std:cluster:libcluster", ":cluster:libcluster", "hex:oban"] do
      assert Facets.requirement?(ok), ok
    end

    for bad <- ["libcluster", ".:dns", "cb_std/debug/echo", "/a/b", "hex:oban@1.0"] do
      refute Facets.requirement?(bad), bad
      assert {:error, "invalid requires entry" <> _} = Facets.validate(requires: [bad])
    end
  end

  test "an old-syntax requirement compiles with a warning naming the rewrite" do
    assert {:ok, %{requires: ["cb_std:cluster/libcluster"]}, [warning]} =
             Facets.validate(requires: ["cb_std:cluster/libcluster"])

    assert warning =~ ~s(write "cb_std:cluster:libcluster")
    assert warning =~ "--fix"
  end
end
