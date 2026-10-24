defmodule Mix.Tasks.Composer.Recipe.List do
  @shortdoc "Lists recipes, by cookbook or group"

  @moduledoc """
  Lists every cookbook's recipes with their shortdocs, in discovery order.

      $ mix composer.recipe.list
        cb_lab:base/completions  CbLab's base recipe
        cb_lab:ui/test           Scratch recipe for trying out UI steps

      mix composer.recipe.list                 # every cookbook
      mix composer.recipe.list cb_lab          # one cookbook
      mix composer.recipe.list cb_lab cb_mine  # several cookbooks
      mix composer.recipe.list cb_lab:base/    # one group (note the slash)

  Cookbooks are separate arguments, not a comma-separated list. A group
  file that cannot be loaded is reported as a warning, with its path.

  ## Leaf recipes

  A recipe is a *leaf* when no other recipe in its own group includes it
  with `{:use, ...}`. Leaves are the recipes meant to be run directly; the
  others are building blocks for them. Only includes within the same
  cookbook and group count: a recipe that another group or cookbook uses is
  still a leaf in its own group. An include that does not resolve is
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
  alias Composer.Recipe.Group

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
      Enum.reduce(selected, {[], []}, fn {cookbook, group}, {recipes, problems} ->
        {loaded, errors} = Cookbook.load_recipes(cookbook)
        included = included_in_group(index, loaded)

        loaded = if group, do: Enum.filter(loaded, &(&1.group == group)), else: loaded

        loaded =
          loaded
          |> Enum.map(&{&1, &1.ref not in included})
          |> Enum.filter(fn {_recipe, leaf} -> leaf or !opts[:only_leaves] end)

        errors =
          if group, do: Enum.filter(errors, &(Group.name(elem(&1, 0)) == group)), else: errors

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

            mix composer.gen.recipe my_group/my_recipe
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

  # The refs of the recipes that a recipe in their own group includes.
  defp included_in_group(index, recipes) do
    for recipe <- recipes,
        {_written, {:ok, ref}} <- Resolver.included(index, recipe),
        ref != recipe.ref,
        Path.dirname(ref) == recipe.cookbook <> ":" <> recipe.group,
        into: MapSet.new(),
        do: ref
  end

  defp data({recipe, leaf}) do
    %{
      "ref" => recipe.ref,
      "cookbook" => recipe.cookbook,
      "group" => recipe.group,
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

  # An argument is a cookbook name, or "cookbook:group/" for one group.
  defp select!(arg, cookbooks) do
    case String.split(arg, ":", parts: 2) do
      [name] ->
        {cookbook!(name, arg, cookbooks), nil}

      [name, group_slash] ->
        group =
          case String.split(group_slash, "/") do
            [group, ""] -> group
            _ -> nil
          end

        unless group && Group.valid_name?(group) do
          Mix.raise("""
          Invalid argument #{inspect(arg)}. List a group as "cookbook:group/", with a \
          trailing slash (e.g. cb_lab:base/), or a whole cookbook by name.
          """)
        end

        cookbook = cookbook!(name, arg, cookbooks)

        unless Cookbook.group_path(cookbook, group) do
          groups = Enum.map(Cookbook.groups(cookbook), &elem(&1, 0))

          known =
            case groups do
              [] -> "#{name} has no recipe groups."
              groups -> "Groups in #{name}: " <> Enum.map_join(groups, ", ", &"#{name}:#{&1}/")
            end

          Mix.raise("#{name} has no recipe group #{inspect(group)}.\n\n#{known}")
        end

        {cookbook, group}
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
