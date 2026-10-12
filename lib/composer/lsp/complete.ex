defmodule Composer.LSP.Complete do
  @moduledoc """
  Completion items for a context from `Composer.LSP.Cursor.context/3`.

  In a `steps:` literal: every step id, every recipe id, and the current
  recipe's alias prefixes (with the ids they reach). In `{:use, "`:
  recipe ids only. Items are built from the entries of the completion
  index (`Composer.Index`), as `%{label, kind, detail, range}` where
  `kind` is `:step`, `:recipe` or `:alias` and `range` is the literal's
  contents, which the item replaces.
  """

  alias Composer.Ref

  @type item :: %{
          label: String.t(),
          kind: :step | :recipe | :alias,
          detail: String.t(),
          range: Composer.Lint.Diagnostic.range()
        }

  @doc """
  The items for `context`, from `entries` (`{kind, id, text}`) and the
  recipe's `aliases` (`%{"lab" => "composer_lab"}`).
  """
  @spec items({:steps | :use, String.t(), Composer.Lint.Diagnostic.range()} | nil, list(), map()) ::
          [item()]
  def items(nil, _entries, _aliases), do: []

  def items({kind, _prefix, range}, entries, aliases) do
    wanted = if kind == :use, do: ["recipe"], else: ["step", "recipe"]

    found =
      for {type, id, text} <- entries,
          type in wanted,
          do: {String.to_existing_atom(type), id, text || ""}

    aliased =
      for {name, target} <- Enum.sort(aliases),
          {type, id, text} <- found,
          {:ok, %Ref{cookbook: ^target, path: path}} <- [Ref.parse(id)],
          do: {type, Ref.id(name, path), text}

    prefixes =
      if kind == :steps,
        do:
          for(
            {name, target} <- Enum.sort(aliases),
            do: {:alias, name <> ":", "alias for #{target}"}
          ),
        else: []

    for {type, label, detail} <- prefixes ++ found ++ aliased,
        uniq: true,
        do: %{label: label, kind: type, detail: detail, range: range}
  end
end
