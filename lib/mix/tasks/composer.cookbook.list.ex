defmodule Mix.Tasks.Composer.Cookbook.List do
  @shortdoc "Lists the discovered cookbooks"

  @moduledoc """
  Lists every cookbook composer found, with its package and how many steps
  and recipes it holds.

      $ mix composer.cookbook.list
        core          composer      29 steps  0 recipes  Composer's built-in steps for Phoenix apps
        cc_lab  cc_lab  41 steps  6 recipes  Andy's composer steps
        cb_mine       cb_mine        0 steps  3 recipes  Composer steps and recipes for cb_mine

  A dependency's cookbook is found when the dependency ships
  `lib/composer/<package>.ex`. See `Composer.Discovery`.

  ## Options

    * `--json` - print JSON instead of text
  """

  use Mix.Task

  alias Composer.{CLI, Cookbook}

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = CLI.parse!(argv)
    cookbooks = CLI.cookbooks!()
    data = Enum.map(cookbooks, &data/1)

    if opts[:json] do
      CLI.json(%{"cookbooks" => data})
    else
      data
      |> Enum.map(fn r ->
        [
          r["name"],
          r["package"] || "",
          "#{r["steps"]} steps",
          "#{r["recipes"]} recipes",
          r["summary"] || ""
        ]
      end)
      |> CLI.table()
      |> Mix.shell().info()
    end
  end

  defp data(cookbook) do
    %{
      "name" => cookbook.name,
      "package" => cookbook.app && Atom.to_string(cookbook.app),
      "kind" => Atom.to_string(cookbook.kind),
      "steps" => length(Cookbook.steps(cookbook)),
      "recipes" => length(Cookbook.recipes(cookbook)),
      "summary" => cookbook.summary,
      "homepage" => cookbook.homepage,
      "source_dir" => Cookbook.source_dir(cookbook)
    }
  end
end
