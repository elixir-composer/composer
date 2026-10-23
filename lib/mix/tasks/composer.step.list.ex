defmodule Mix.Tasks.Composer.Step.List do
  @shortdoc "Lists steps"

  @moduledoc """
  Lists the steps of every cookbook, optionally filtered.

      mix composer.step.list
      mix composer.step.list --cookbook core --action remove
      mix composer.step.list --framework ash --tag postgres
      mix composer.step.list --json

  ## Options

    * `--cookbook NAME` - only steps of this cookbook
    * `--framework NAME` - only steps targeting this framework
    * `--action NAME` - only steps with this action (add, remove, gen, ...)
    * `--tag NAME` - only steps with this tag
    * `--json` - print JSON instead of text
  """

  use Mix.Task

  alias Composer.{CLI, Cookbook}
  alias Composer.Step.Meta

  @filters [cookbook: :string, framework: :string, action: :string, tag: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = CLI.parse!(argv, @filters)

    steps =
      CLI.cookbooks!(quiet: opts[:json])
      |> Enum.flat_map(&Cookbook.steps/1)
      |> Enum.filter(&keep?(&1, opts))

    print(steps, opts[:json])
  end

  @doc false
  # Shared with mix composer.step.find.
  def print(steps, json?) do
    cond do
      json? ->
        CLI.json(%{"steps" => Enum.map(steps, &Meta.to_data/1)})

      steps == [] ->
        Mix.shell().info("No steps found.")

      true ->
        steps
        |> Enum.map(&[&1.ref, to_string(&1.action || ""), &1.summary || ""])
        |> CLI.table()
        |> Mix.shell().info()
    end
  end

  defp keep?(meta, opts) do
    data = Meta.to_data(meta)

    (opts[:cookbook] == nil or meta.cookbook == opts[:cookbook]) and
      (opts[:action] == nil or data["action"] == opts[:action]) and
      (opts[:framework] == nil or opts[:framework] in data["frameworks"]) and
      (opts[:tag] == nil or opts[:tag] in data["tags"])
  end
end
