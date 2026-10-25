defmodule Mix.Tasks.Composer.Recipe.List do
  @shortdoc "Lists recipes, by cookbook or chapter"

  @moduledoc """
  Lists every cookbook's recipes with their shortdocs, in discovery order.

      $ mix composer.recipe.list
        cb_lab:base/completions  CbLab's base recipe
        cb_lab:ui/test           Scratch recipe for trying out UI steps

      mix composer.recipe.list                 # every cookbook
      mix composer.recipe.list cb_lab          # one cookbook
      mix composer.recipe.list cb_lab cb_mine  # several cookbooks
      mix composer.recipe.list cb_lab:base/    # one chapter (note the slash)

  Cookbooks are separate arguments, not a comma-separated list. A chapter
  file that cannot be loaded is reported as a warning, with its path.

  ## Leaf recipes

  A recipe is a *leaf* when no other recipe in its own chapter includes it
  with `{:use, ...}`. Leaves are the recipes meant to be run directly; the
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

        loaded = if chapter, do: Enum.filter(loaded, &(&1.chapter == chapter)), else: loaded

        loaded =
          loaded
          |> Enum.map(&{&1, &1.ref not in included})
          |> Enum.filter(fn {_recipe, leaf} -> leaf or !opts[:only_leaves] end)

        errors =
          if chapter,
            do: Enum.filter(errors, &(Chapter.path(elem(&1, 0)) == chapter)),
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

  # The refs of the recipes that a recipe in their own chapter includes.
  defp included_in_chapter(index, recipes) do
    for recipe <- recipes,
        {_written, {:ok, ref}} <- Resolver.included(index, recipe),
        ref != recipe.ref,
        Path.dirname(ref) == recipe.cookbook <> ":" <> recipe.chapter,
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

  # An argument is a cookbook name, or "cookbook:chapter/" for one chapter.
  defp select!(arg, cookbooks) do
    case String.split(arg, ":", parts: 2) do
      [name] ->
        {cookbook!(name, arg, cookbooks), nil}

      [name, chapter_slash] ->
        chapter =
          case String.split(chapter_slash, "/") do
            [chapter, ""] -> chapter
            _ -> nil
          end

        unless chapter && Chapter.valid_name?(chapter) do
          Mix.raise("""
          Invalid argument #{inspect(arg)}. List a chapter as "cookbook:chapter/", with a \
          trailing slash (e.g. cb_lab:base/), or a whole cookbook by name.
          """)
        end

        cookbook = cookbook!(name, arg, cookbooks)

        unless Cookbook.chapter_path(cookbook, chapter) do
          chapters = Enum.map(Cookbook.chapters(cookbook), &elem(&1, 0))

          known =
            case chapters do
              [] ->
                "#{name} has no chapters."

              chapters ->
                "Chapters in #{name}: " <> Enum.map_join(chapters, ", ", &"#{name}:#{&1}/")
            end

          Mix.raise("#{name} has no chapter #{inspect(chapter)}.\n\n#{known}")
        end

        {cookbook, chapter}
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
