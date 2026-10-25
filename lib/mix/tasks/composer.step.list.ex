defmodule Mix.Tasks.Composer.Step.List do
  @shortdoc "Lists steps"

  @moduledoc """
  Lists the steps of every cookbook, optionally filtered.

      mix composer.step.list
      mix composer.step.list cb_std:cluster:      # the steps under a stem
      mix composer.step.list :                    # this project's cookbook
      mix composer.step.list --cookbook cb_std --action remove
      mix composer.step.list --framework ash --tag postgres
      mix composer.step.list --json

  A positional argument is a listing stem, a step address cut after a `:`:
  `cb_std:`, `cb_std:cluster:`, or `:` and `:setup:` for this project's
  cookbook. A bare cookbook name also works.

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
    {opts, args} = CLI.parse!(argv, @filters)
    cookbooks = CLI.cookbooks!(quiet: opts[:json])
    stems = Enum.map(args, &stem!(&1, cookbooks))

    steps =
      cookbooks
      |> Enum.flat_map(&Cookbook.steps/1)
      |> Enum.filter(&keep?(&1, opts))
      |> Enum.filter(fn meta -> stems == [] or Enum.any?(stems, &under?(meta, &1)) end)

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

  defp stem!(arg, cookbooks) do
    case {Composer.Ref.parse(arg), Composer.Ref.parse_stem(arg)} do
      {{:ok, %Composer.Ref{scope: :search, segments: [name]}}, _} ->
        {name, []}

      {_, {:ok, %{kind: :step, cookbook: name, segments: segments}}} ->
        case name || CLI.context(cookbooks).cookbook do
          nil -> Mix.raise(Composer.Error.message({:not_a_cookbook, arg, nil}))
          name -> {name, segments}
        end

      _ ->
        Mix.raise("""
        Invalid argument #{inspect(arg)}. List steps by cookbook (cb_std) or a \
        stem ending in : (cb_std:, cb_std:cluster:, or : in this project's cookbook).
        """)
    end
  end

  defp under?(meta, {cookbook, segments}) do
    id = String.split(meta.id, "/")

    meta.cookbook == cookbook and length(id) > length(segments) and
      Enum.take(id, length(segments)) == segments
  end

  defp keep?(meta, opts) do
    data = Meta.to_data(meta)

    (opts[:cookbook] == nil or meta.cookbook == opts[:cookbook]) and
      (opts[:action] == nil or data["action"] == opts[:action]) and
      (opts[:framework] == nil or opts[:framework] in data["frameworks"]) and
      (opts[:tag] == nil or opts[:tag] in data["tags"])
  end
end
