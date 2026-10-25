defmodule Composer.LSP.Actions do
  @moduledoc """
  Quick fixes from lint's fixes and suggestions.

  `Composer.LSP.Convert` puts each diagnostic's fix and suggestions in its
  `data`. A diagnostic with one rewrite (an address in the old syntax, a
  `{:use, ...}` entry, a bare word with one match, a kind mismatch) gets
  one preferred fix, replacing its range with the rewrite. Otherwise each
  suggestion replaces the diagnostic's range, which covers the address
  string, quotes included, with the quoted suggestion.
  """

  @doc """
  The quick fixes for `diagnostics`, LSP diagnostics of the document at
  `uri` (maps or GenLSP structures with `range` and `data`). `quoted?`
  tells whether a diagnostic's range starts at a string's opening quote;
  one that does not (a fallback range, such as a `steps:` key) gets no
  suggestion fix.
  """
  @spec for_diagnostics(String.t(), [map()], (map() -> boolean())) :: [map()]
  def for_diagnostics(uri, diagnostics, quoted? \\ fn _diagnostic -> true end) do
    Enum.flat_map(diagnostics, fn diagnostic ->
      case data(diagnostic) do
        %{"fix" => text} when is_binary(text) ->
          [action(uri, diagnostic, "Rewrite as #{text}", text, true)]

        %{"suggestions" => suggestions} when is_list(suggestions) and suggestions != [] ->
          if quoted?.(diagnostic) do
            suggestions = Enum.filter(suggestions, &is_binary/1)

            for {suggestion, n} <- Enum.with_index(suggestions) do
              preferred? = n == 0 and length(suggestions) == 1

              action(
                uri,
                diagnostic,
                "Replace with `#{suggestion}`",
                inspect(suggestion),
                preferred?
              )
            end
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp action(uri, diagnostic, title, text, preferred?) do
    %{
      title: title,
      kind: "quickfix",
      diagnostics: [diagnostic],
      is_preferred: preferred?,
      edit: %{changes: %{uri => [%{range: diagnostic.range, new_text: text}]}}
    }
  end

  defp data(diagnostic) do
    case Map.get(diagnostic, :data) do
      %{} = data -> data
      _ -> %{}
    end
  end
end
