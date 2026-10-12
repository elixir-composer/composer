defmodule Composer.LSP.Actions do
  @moduledoc """
  Quick fixes from lint's suggestions.

  `Composer.LSP.Convert` puts each diagnostic's suggestions in its
  `data`. A diagnostic's range covers the reference string, quotes
  included, so each suggestion replaces it with the quoted suggestion.
  """

  @doc """
  The quick fixes for `diagnostics`, LSP diagnostics of the document at
  `uri` (maps or GenLSP structures with `range` and `data`). `quoted?`
  tells whether a diagnostic's range starts at a string's opening quote;
  one that does not (a fallback range, such as a `steps:` key) gets no
  fix.
  """
  @spec for_diagnostics(String.t(), [map()], (map() -> boolean())) :: [map()]
  def for_diagnostics(uri, diagnostics, quoted? \\ fn _diagnostic -> true end) do
    for diagnostic <- diagnostics,
        suggestions = suggestions(diagnostic),
        suggestions != [],
        quoted?.(diagnostic),
        {suggestion, n} <- Enum.with_index(suggestions) do
      %{
        title: "Replace with `#{suggestion}`",
        kind: "quickfix",
        diagnostics: [diagnostic],
        is_preferred: n == 0 and length(suggestions) == 1,
        edit: %{changes: %{uri => [%{range: diagnostic.range, new_text: inspect(suggestion)}]}}
      }
    end
  end

  defp suggestions(diagnostic) do
    case Map.get(diagnostic, :data) do
      %{"suggestions" => suggestions} when is_list(suggestions) ->
        Enum.filter(suggestions, &is_binary/1)

      _ ->
        []
    end
  end
end
