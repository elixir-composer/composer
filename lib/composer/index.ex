defmodule Composer.Index do
  @moduledoc """
  The shell completion index: `_build/composer/index`.

  A plain-text file of tab-separated lines, with canonical addresses (see
  `Composer.Ref`), that the completion script reads without starting the
  BEAM:

      self	my_app
      cookbook	cb_lab	Andy's composer steps
      dir	cb_lab/ash/	1 chapter, 1 directory
      chapter	cb_lab/ash/ui/	2 recipes
      recipe	cb_lab/ash/ui/buttons	Button components
      group	cb_std:cluster:	3 steps
      step	cb_std:setup:credo	Adds Credo for static code analysis

  `dir` is a directory under `recipes/` and `group` a step namespace, so
  completion can stop at every segment. `self` names the current project's
  own cookbook, for the root addresses `/...` and `:...`; it is absent when
  the project is not a cookbook.

  Cookbooks are read from their committed manifests. A cookbook with no
  manifest, or one that fails to read, falls back to runtime metadata: its
  chapter files are evaluated to read their shortdocs, and a chapter that fails
  to load lists its recipes with no shortdoc and never fails the refresh.

  Every composer task refreshes the index as a side effect, and
  `mix composer.index` rebuilds it explicitly. The scripts that read it
  are the templates of `cb_std:completions:composer`; a change to these lines needs a matching
  change to them. See the [completion guide](completion.md).
  """

  alias Composer.{Manifest, Ref, Cookbook}

  @doc "The index path for the current project."
  @spec path() :: Path.t()
  def path, do: Path.join([Path.dirname(Mix.Project.build_path()), "composer", "index"])

  @doc "Builds the index lines for `cookbooks`."
  @spec lines([Cookbook.t()]) :: [String.t()]
  def lines(cookbooks) do
    own =
      case Composer.Discovery.own(cookbooks) do
        nil -> []
        cookbook -> [{"self", cookbook.name, nil}]
      end

    (own ++ Enum.flat_map(cookbooks, &entries/1))
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
          {Enum.map(data.steps, &{internal(&1.id), &1.summary}),
           Enum.map(data.recipes, &{internal(&1.id), &1[:shortdoc]})}

        _ ->
          {Enum.map(Cookbook.steps(cookbook), &{&1.id, &1.summary}),
           Enum.map(Manifest.recipes(cookbook), &{&1.id, &1.shortdoc})}
      end

    chapters = recipes |> Enum.map(&Path.dirname(elem(&1, 0))) |> Enum.frequencies()
    dirs = chapters |> Map.keys() |> Enum.flat_map(&parents/1) |> Enum.uniq()

    [{"cookbook", name, cookbook.summary}] ++
      Enum.map(chapters, fn {chapter, count} ->
        {"chapter", Ref.id(:recipe, name, chapter) <> "/", count(count, "recipe")}
      end) ++
      Enum.map(dirs, &{"dir", Ref.id(:recipe, name, &1) <> "/", dir_text(&1, chapters, dirs)}) ++
      Enum.map(recipes, fn {id, shortdoc} ->
        {"recipe", Ref.id(:recipe, name, id), first_line(shortdoc)}
      end) ++
      groups(name, steps) ++
      Enum.map(steps, fn {id, summary} -> {"step", Ref.id(:step, name, id), summary} end)
  end

  # A manifest id is canonical (cb/a/b, cb:a:b); internally it is a/b.
  defp internal(id) do
    case Ref.parse(id) do
      {:ok, %Ref{scope: :qualified} = ref} -> Ref.path(ref)
      _ -> id
    end
  end

  # The directories a chapter path is in: ash/ui/tailwind is in ash and ash/ui.
  defp parents(chapter) do
    segments = String.split(chapter, "/")
    for n <- 1..(length(segments) - 1)//1, do: segments |> Enum.take(n) |> Enum.join("/")
  end

  defp dir_text(dir, chapters, dirs) do
    files = Enum.count(Map.keys(chapters), &(Path.dirname(&1) == dir))
    subdirs = Enum.count(dirs, &(Path.dirname(&1) == dir))
    count(files, "chapter") <> ", " <> count(subdirs, "directory", "directories")
  end

  # Every step namespace, with the number of steps under it.
  defp groups(name, steps) do
    steps
    |> Enum.flat_map(fn {id, _summary} -> parents(id) end)
    |> Enum.frequencies()
    |> Enum.map(fn {group, count} ->
      {"group", Ref.id(:step, name, group) <> ":", count(count, "step")}
    end)
  end

  defp count(n, one, many \\ nil), do: "#{n} #{if n == 1, do: one, else: many || one <> "s"}"

  defp first_line(nil), do: ""
  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp clean(nil), do: ""
  defp clean(text), do: String.replace(text, ["\t", "\n"], " ")
end
