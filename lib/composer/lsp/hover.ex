defmodule Composer.LSP.Hover do
  @moduledoc """
  Renders a `Composer.LSP.Lookup` result as Markdown for a hover. Every
  hover ends with a footer naming the host project, since a reference
  valid in one host may not be in another.
  """

  alias Composer.{CLI, Error, Recipe, Resolver}
  alias Composer.Step.Meta

  @doc """
  The hover text of `result`, or `nil`. `host` is `%{project, root}`;
  `cookbooks` resolve a recipe's entries.
  """
  @spec render(Composer.LSP.Lookup.result(), map(), [Composer.Cookbook.t()]) :: String.t() | nil
  def render(result, host, cookbooks \\ [])
  def render(nil, _host, _cookbooks), do: nil

  def render(result, host, cookbooks), do: body(result, cookbooks) <> footer(host)

  @doc "The footer naming the host project."
  @spec footer(map()) :: String.t()
  def footer(%{project: project, root: root}),
    do: "\n\n---\n_composer-ls · host: #{project} (#{root})_"

  defp body({:step, meta}, _cookbooks) do
    table =
      Enum.map_join(Meta.rows(meta), "\n", fn {label, value} ->
        "| #{label} | #{cell(value)} |"
      end)

    [
      "**#{meta.ref}** - #{meta.summary || "(no summary)"}\n\n| | |\n|:--|:--|\n",
      table,
      moduledoc(meta)
    ]
    |> IO.iodata_to_binary()
  end

  defp body({:recipe, %Recipe{} = recipe}, cookbooks) do
    flags =
      case recipe.flags do
        [] ->
          ""

        flags ->
          "\n\nFlags:\n\n" <>
            Enum.map_join(flags, "\n", fn {flag, doc} -> "- `#{CLI.switch(flag)}` - #{doc}" end)
      end

    entries =
      case Resolver.resolve_recipe(cookbooks, recipe.ref, flags: :all, context: recipe.cookbook) do
        {:ok, %{steps: steps}} -> CLI.render_entries(steps, aliases: true)
        {:error, _} -> Enum.map_join(recipe.steps, "\n", &("  " <> inspect(&1)))
      end

    doc = if recipe.doc, do: "\n\n" <> String.trim(recipe.doc), else: ""

    "**#{recipe.ref}** - #{String.trim(recipe.shortdoc || "")}" <>
      doc <> flags <> "\n\n```\n" <> entries <> "\n```"
  end

  defp body({:hex, package, kind}, _cookbooks) do
    note = package |> Meta.hex_note() |> String.trim() |> unwrap()

    case kind do
      :explicit ->
        note

      :fallthrough ->
        "No cookbook has a step named `#{package}`, so it names a Hex package.\n\n" <> note
    end
  end

  defp body({:alias, name, nil}, _cookbooks), do: "`#{name}` is a cookbook alias"

  defp body({:alias, name, target}, _cookbooks),
    do: "`#{name}` is an alias for cookbook `#{target}`"

  defp body({:error, reason}, _cookbooks), do: String.trim(Error.message(reason))

  defp moduledoc(meta) do
    case Code.fetch_docs(meta.module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
        if String.trim(doc) == String.trim(meta.summary || ""),
          do: "",
          else: "\n\n" <> String.trim(doc)

      _ ->
        ""
    end
  end

  # Joins the hard-wrapped lines of each paragraph.
  defp unwrap(text) do
    text
    |> String.split("\n\n")
    |> Enum.map_join("\n\n", &String.replace(&1, "\n", " "))
  end

  defp cell(value), do: String.replace(value, "|", "\\|")
end
