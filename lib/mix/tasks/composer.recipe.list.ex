defmodule Mix.Tasks.Composer.Recipe.List do
  @shortdoc "Lists recipes, by cookbook or group"

  @moduledoc """
  Lists recipes with their shortdocs: your `local:` recipes first, then
  every cookbook's.

      $ mix composer.recipe.list
        local:ash/base        Ash core: sourceror, ash and ash_phoenix
        local:ash/auth        Ash with authentication, admin, TUI and accounts
        composer_lab:lv/base  LiveView base

      mix composer.recipe.list                    # every cookbook
      mix composer.recipe.list local              # one cookbook
      mix composer.recipe.list local composer_lab # several cookbooks
      mix composer.recipe.list local:ash/         # one group (note the slash)

  Cookbooks are separate arguments, not a comma-separated list. A group
  file that cannot be loaded is reported as a warning, with its path.

  ## Options

    * `-c`, `--config` - the local config directory (see `Composer.Local`)
    * `--json` - print JSON instead of text
  """

  use Mix.Task

  alias Composer.{CLI, Error, Recipe, Cookbook}
  alias Composer.Recipe.Group

  @impl Mix.Task
  def run(argv) do
    {opts, args} = CLI.parse!(argv)
    cookbooks = CLI.cookbooks!(opts[:config])

    check_commas!(args)
    selected = Enum.map(args, &select!(&1, cookbooks))

    # Local first: those are your own.
    selected =
      case selected do
        [] ->
          {local, others} =
            cookbooks
            |> Enum.reject(&(&1.kind == :virtual))
            |> Enum.split_with(&(&1.kind == :local))

          Enum.map(local ++ others, &{&1, nil})

        selected ->
          Enum.uniq(selected)
      end

    {recipes, problems} =
      Enum.reduce(selected, {[], []}, fn {cookbook, group}, {recipes, problems} ->
        {loaded, errors} = Cookbook.load_recipes(cookbook)

        loaded = if group, do: Enum.filter(loaded, &(&1.group == group)), else: loaded

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
        {dir, _how} = Composer.Local.dir(opts[:config])

        Mix.shell().info("""
        No recipes found. Create one in #{dir} with:

            mix composer.gen.recipe my_group/my_recipe --local
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

  defp data(recipe) do
    %{
      "ref" => recipe.ref,
      "cookbook" => recipe.cookbook,
      "group" => recipe.group,
      "name" => recipe.name,
      "id" => recipe.id,
      "shortdoc" => recipe.shortdoc,
      "path" => recipe.path
    }
  end

  defp print_warnings(warnings) do
    Enum.each(warnings, &Mix.shell().info([:yellow, "warning: ", &1, :reset]))
  end

  # The shell passes "local, composer_lab" as "local," and "composer_lab".
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
          trailing slash (e.g. local:ash/), or a whole cookbook by name.
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
