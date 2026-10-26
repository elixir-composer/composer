defmodule Mix.Tasks.Composer.Recipe.List do
  @shortdoc "Lists recipes, by cookbook or chapter"

  @moduledoc """
  Lists every cookbook's recipes with their shortdocs, in discovery order.

      $ mix composer.recipe.list
        cb_std/completions/install  Installs shell completion for mix and composer
        cb_lab/ui/test              Scratch recipe for trying out UI steps

      mix composer.recipe.list                 # every cookbook
      mix composer.recipe.list cb_lab          # one cookbook (or cb_lab/)
      mix composer.recipe.list cb_lab cb_mine  # several cookbooks
      mix composer.recipe.list cb_lab/base/    # one chapter, and those nested in it
      mix composer.recipe.list /ash/           # a chapter of this project's cookbook

  An argument is a cookbook name or a listing stem, an address cut after a
  `/`: `cb_lab/`, `cb_lab/ash/ui/`, or `/` and `/ash/` for this project's
  cookbook. A stem lists the recipes of the chapters at and below it.
  Arguments are separate, not a comma-separated list. A chapter file that
  cannot be loaded is reported as a warning, with its path.

  ## Leaf recipes

  A recipe is a *leaf* when no other recipe in its own chapter includes it. Leaves are the recipes meant to be run directly; the
  others are building blocks for them. Only includes within the same
  cookbook and chapter count: a recipe that another chapter or cookbook uses is
  still a leaf in its own chapter. An include that does not resolve is
  ignored.

      mix composer.recipe.list cb_lab:base/ --only-leaves

  `--only-leaves` only hides recipes from the listing; every recipe can
  still be run. The JSON output marks each recipe with `"leaf"`, with or
  without the option.

  ## Options

    * `--json` - print JSON instead of text
    * `--only-leaves` - list only leaf recipes (see above)
  """

  use Mix.Task

  alias Composer.{CLI, Error, Recipe, Cookbook, Resolver}
  alias Composer.Recipe.Chapter

  @impl Mix.Task
  def run(argv) do
    {opts, args} = CLI.parse!(argv, only_leaves: :boolean)
    cookbooks = CLI.cookbooks!(quiet: opts[:json])
    index = Resolver.index(cookbooks)

    check_commas!(args)
    selected = Enum.map(args, &select!(&1, cookbooks))

    selected =
      case selected do
        [] ->
          for cookbook <- cookbooks, cookbook.kind != :virtual, do: {cookbook, nil}

        selected ->
          Enum.uniq(selected)
      end

    {recipes, problems} =
      Enum.reduce(selected, {[], []}, fn {cookbook, chapter}, {recipes, problems} ->
        {loaded, errors} = Cookbook.load_recipes(cookbook)
        included = included_in_chapter(index, loaded)

        loaded =
          if chapter, do: Enum.filter(loaded, &in_chapter?(&1.chapter, chapter)), else: loaded

        loaded =
          loaded
          |> Enum.map(&{&1, &1.ref not in included})
          |> Enum.filter(fn {_recipe, leaf} -> leaf or !opts[:only_leaves] end)

        errors =
          if chapter,
            do: Enum.filter(errors, &in_chapter?(Chapter.path(elem(&1, 0)), chapter)),
            else: errors

        {recipes ++ Enum.map(loaded, &data/1), problems ++ errors}
      end)

    warnings =
      Enum.map(problems, fn {_path, reason} -> reason |> Error.message() |> String.trim() end)

    cond do
      opts[:json] ->
        CLI.json(%{"recipes" => recipes, "warnings" => warnings})

      recipes == [] and args == [] ->
        Mix.shell().info("""
        No recipes found. Create one in this project's cookbook with:

            mix composer.gen.recipe my_chapter/my_recipe
        """)

        print_warnings(warnings)

      recipes == [] ->
        Mix.shell().info("No recipes found.")
        print_warnings(warnings)

      true ->
        recipes
        |> Enum.map(&[&1["ref"], Recipe.summary(&1["shortdoc"])])
        |> CLI.table()
        |> Mix.shell().info()

        print_warnings(warnings)
    end
  end

  defp in_chapter?(chapter, stem),
    do: chapter == stem or String.starts_with?(chapter, stem <> "/")

  # The refs of the recipes that a recipe in their own chapter includes.
  defp included_in_chapter(index, recipes) do
    for recipe <- recipes,
        {_written, {:ok, ref}} <- Resolver.included(index, recipe),
        ref != recipe.ref,
        Path.dirname(ref) == recipe.cookbook <> "/" <> recipe.chapter,
        into: MapSet.new(),
        do: ref
  end

  defp data({recipe, leaf}) do
    %{
      "ref" => recipe.ref,
      "cookbook" => recipe.cookbook,
      "chapter" => recipe.chapter,
      "name" => recipe.name,
      "id" => recipe.id,
      "shortdoc" => recipe.shortdoc,
      "path" => recipe.path,
      "leaf" => leaf
    }
  end

  defp print_warnings(warnings) do
    Enum.each(warnings, &Mix.shell().info([:yellow, "warning: ", &1, :reset]))
  end

  # The shell passes "cb_lab, cb_mine" as "cb_lab," and "cb_mine".
  defp check_commas!(args) do
    if Enum.any?(args, &String.contains?(&1, ",")) do
      names = Enum.flat_map(args, &String.split(&1, ",", trim: true))

      Mix.raise("""
      Cookbooks are separate arguments, not a comma-separated list:

          mix composer.recipe.list #{Enum.join(names, " ")}
      """)
    end
  end

  # An argument is a cookbook name, or a stem: "cookbook/", "cookbook/chapter/",
  # "/" or "/chapter/" (this project's cookbook).
  defp select!(arg, cookbooks) do
    case {Composer.Ref.parse(arg), Composer.Ref.parse_stem(arg)} do
      {{:ok, %Composer.Ref{scope: :search, segments: [name]}}, _} ->
        {cookbook!(name, arg, cookbooks), nil}

      {_, {:ok, %{kind: :recipe, cookbook: name, segments: segments}}} ->
        name = name || own!(arg, cookbooks)
        cookbook = cookbook!(name, arg, cookbooks)

        case Enum.join(segments, "/") do
          "" -> {cookbook, nil}
          chapter -> {cookbook, chapter!(cookbook, chapter, arg)}
        end

      _ ->
        Mix.raise("""
        Invalid argument #{inspect(arg)}. List a cookbook by name (cb_lab) or a \
        stem ending in / (cb_lab/, cb_lab/base/, or /base/ in this project's \
        cookbook).
        """)
    end
  end

  defp own!(arg, cookbooks) do
    case Composer.CLI.context(cookbooks).cookbook do
      nil -> Mix.raise(Error.message({:not_a_cookbook, arg, nil}))
      name -> name
    end
  end

  # A stem names a chapter, or a directory of chapters.
  defp chapter!(cookbook, chapter, arg) do
    chapters = Enum.map(Cookbook.chapters(cookbook), &elem(&1, 0))

    if Enum.any?(chapters, &in_chapter?(&1, chapter)) do
      chapter
    else
      known =
        case chapters do
          [] ->
            "#{cookbook.name} has no chapters."

          chapters ->
            "Chapters in #{cookbook.name}: " <>
              Enum.map_join(chapters, ", ", &"#{cookbook.name}/#{&1}/")
        end

      Mix.raise("#{cookbook.name} has no chapter #{inspect(chapter)} (#{arg}).\n\n#{known}")
    end
  end

  defp cookbook!(name, arg, cookbooks) do
    case Enum.find(cookbooks, &(&1.name == name and &1.kind != :virtual)) do
      nil ->
        known = for r <- cookbooks, r.kind != :virtual, do: r.name
        Mix.raise(Error.message({:unknown_cookbook, name, arg, nil, known}))

      cookbook ->
        cookbook
    end
  end
end
