defmodule Composer.Index do
  @moduledoc """
  The shell completion index: `_build/composer/index`.

  A plain-text file of tab-separated lines that the completion script reads
  without starting the BEAM:

      cookbook	cb_lab	Andy's composer steps
      chapter	cb_lab:base/	1 recipe
      recipe	cb_lab:base/completions	CbLab's base recipe
      step	cb_std:setup/credo	Adds Credo for static code analysis

  Cookbooks are read from their committed manifests. A cookbook with no
  manifest, or one that fails to read, falls back to runtime metadata: its
  chapter files are evaluated to read their shortdocs, and a chapter that fails
  to load lists its recipes with no shortdoc and never fails the refresh.

  Every composer task refreshes the index as a side effect, and
  `mix composer.index` rebuilds it explicitly.
  """

  alias Composer.{Manifest, Ref, Cookbook}

  @doc "The index path for the current project."
  @spec path() :: Path.t()
  def path, do: Path.join([Path.dirname(Mix.Project.build_path()), "composer", "index"])

  @doc "Builds the index lines for `cookbooks`."
  @spec lines([Cookbook.t()]) :: [String.t()]
  def lines(cookbooks) do
    cookbooks
    |> Enum.flat_map(&entries/1)
    |> Enum.sort()
    |> Enum.map(fn {kind, id, text} -> Enum.join([kind, id, clean(text)], "\t") end)
  end

  @doc "Writes the index atomically (a temp file, then a rename)."
  @spec write([Cookbook.t()], Path.t()) :: :ok
  def write(cookbooks, path \\ path()) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, Enum.map(lines(cookbooks), &[&1, "\n"]))
    File.rename!(tmp, path)
  end

  @doc false
  # The cheap side effect every task runs. It never fails a task.
  def refresh(cookbooks) do
    if Application.get_env(:composer, :write_index, true) and Mix.Project.get() do
      write(cookbooks)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  # A cookbook's index entries, as {kind, id, text}; the language server
  # completes from them.
  def entries(%Cookbook{kind: :virtual}), do: []

  def entries(%Cookbook{name: name} = cookbook) do
    {steps, recipes} =
      case cookbook.kind == :code && Manifest.read(cookbook) do
        {:ok, data} ->
          {Enum.map(data.steps, &{&1.id, &1.summary}),
           Enum.map(data.recipes, &{&1.id, &1[:shortdoc]})}

        _ ->
          {Enum.map(Cookbook.steps(cookbook), &{&1.id, &1.summary}),
           Enum.map(Manifest.recipes(cookbook), &{&1.id, &1.shortdoc})}
      end

    chapters =
      recipes
      |> Enum.map(&Path.dirname(elem(&1, 0)))
      |> Enum.frequencies()
      |> Enum.map(fn {chapter, count} ->
        {"chapter", Ref.id(name, chapter <> "/"), "#{count} recipe#{if count != 1, do: "s"}"}
      end)

    [{"cookbook", name, cookbook.summary}] ++
      chapters ++
      Enum.map(recipes, fn {id, shortdoc} ->
        {"recipe", Ref.id(name, id), first_line(shortdoc)}
      end) ++
      Enum.map(steps, fn {id, summary} -> {"step", Ref.id(name, id), summary} end)
  end

  defp first_line(nil), do: ""
  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp clean(nil), do: ""
  defp clean(text), do: String.replace(text, ["\t", "\n"], " ")
end
