defmodule Composer.LSP.ActionsTest do
  use ExUnit.Case, async: true

  alias Composer.Lint.Diagnostic
  alias Composer.LSP.{Actions, Convert}

  @uri "file:///r/recipes/a.exs"

  test "a typo's suggestion replaces the quoted reference" do
    typo =
      :error
      |> Diagnostic.new({:typo, "credoo", "mine:a/x", ["core:setup/credo"]})
      |> Diagnostic.locate("/r/recipes/a.exs", {{1, 21}, {1, 29}})
      |> Convert.diagnostic(:utf16, fn _, _ -> ~s|[x: [steps: ["a", "credoo"]]]| end)

    assert [action] = Actions.for_diagnostics(@uri, [typo])
    assert action.title == "Replace with `core:setup/credo`"
    assert action.kind == "quickfix"
    assert action.is_preferred

    assert action.edit.changes == %{
             @uri => [%{range: typo.range, new_text: ~s("core:setup/credo")}]
           }
  end

  test "no fix without suggestions, or off a quote" do
    plain = %{range: %{}, data: %{"code" => "cycle", "suggestions" => []}}
    assert Actions.for_diagnostics(@uri, [plain]) == []

    typo = %{range: %{}, data: %{"suggestions" => ["a", "b"]}}
    assert length(Actions.for_diagnostics(@uri, [typo])) == 2
    assert Actions.for_diagnostics(@uri, [typo], fn _ -> false end) == []
  end
end
