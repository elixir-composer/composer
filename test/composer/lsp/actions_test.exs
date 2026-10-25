defmodule Composer.LSP.ActionsTest do
  use ExUnit.Case, async: true

  alias Composer.Lint.Diagnostic
  alias Composer.LSP.{Actions, Convert}

  @uri "file:///r/recipes/a.exs"

  test "a suggestion replaces the quoted reference" do
    typo =
      :error
      |> Diagnostic.new({:missing_step, "cb_std:credoo", "mine/a/x", ["cb_std:setup:credo"]})
      |> Diagnostic.locate("/r/recipes/a.exs", {{1, 21}, {1, 29}})
      |> Convert.diagnostic(:utf16, fn _, _ -> ~s|[x: [steps: ["a", "credoo"]]]| end)

    assert [action] = Actions.for_diagnostics(@uri, [typo])
    assert action.title == "Replace with `cb_std:setup:credo`"
    assert action.kind == "quickfix"
    assert action.is_preferred

    assert action.edit.changes == %{
             @uri => [%{range: typo.range, new_text: ~s("cb_std:setup:credo")}]
           }
  end

  test "a diagnostic's one rewrite is the preferred fix" do
    old =
      :error
      |> Diagnostic.new({:use_entry, "mine/a/x", {:use, "base"}, [~s("./base")]})
      |> Diagnostic.locate("/r/recipes/a.exs", {{1, 14}, {1, 29}})
      |> Map.put(:fix, %{range: {{1, 14}, {1, 29}}, expect: {:use, "base"}, text: ~s("./base")})
      |> Convert.diagnostic(:utf16, fn _, _ -> ~s|[x: [steps: [{:use, "base"}]]]| end)

    assert [action] = Actions.for_diagnostics(@uri, [old], fn _ -> false end)
    assert action.title == ~s(Rewrite as "./base")
    assert action.is_preferred
    assert action.edit.changes == %{@uri => [%{range: old.range, new_text: ~s("./base")}]}
  end

  test "no fix without suggestions, or off a quote" do
    plain = %{range: %{}, data: %{"code" => "cycle", "suggestions" => []}}
    assert Actions.for_diagnostics(@uri, [plain]) == []

    typo = %{range: %{}, data: %{"suggestions" => ["a", "b"]}}
    assert length(Actions.for_diagnostics(@uri, [typo])) == 2
    assert Actions.for_diagnostics(@uri, [typo], fn _ -> false end) == []
  end
end
