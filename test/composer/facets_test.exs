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
                 "core:setup/credo",
                 {:executable, "bun"},
                 {:package, :phoenix, "~> 1.8"}
               ]
             )
  end
end
