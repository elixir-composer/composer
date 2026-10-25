defmodule Mix.Tasks.Composer.Step.Run do
  @shortdoc "Runs one or more steps"

  @moduledoc """
  Runs one or more steps, as one diff.

      mix composer.step.run cb_std:setup:credo
      mix composer.step.run credo,remove_topbar,hex:oban
      mix composer.step.run cc_lab:ash:postgres --dry-run
      mix composer.step.run cc_lab:foo -- --bar baz
      mix composer.step.run hex:my_lib@path:../my_lib
      mix composer.step.run hex:ash_authentication -- --auth-strategy password

  A step is addressed as `cookbook:path:to:step`, or `:path:to:step` in
  the current project's cookbook. A bare name (`credo`) searches every
  cookbook for the one recipe or step whose last segment it is; it never
  means a Hex package, so write `hex:oban` for one. A `hex:` address may
  name its source after an `@`:
  `hex:ash@3.5`, `hex:ash@github:ash-project/ash`, `hex:x@git:<url>`,
  `hex:my_lib@path:../my_lib` (see `Composer.Ref`). References are split
  on `,`, so a source containing a comma needs a recipe entry instead.

  Arguments after `--` are passed to every step, and to the installer of
  every Hex package.

  `mix composer.step.list` lists the available steps.

  ## Options

    * `--dry-run`, `--yes` - as for any Igniter task
  """

  use Igniter.Mix.Task

  alias Composer.{CLI, Error, Preflight, Resolver}

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      positional: [{:refs, optional: true}],
      example: "mix composer.step.run cb_std:setup:credo,cb_std:setup:quokka"
    }
  end

  @impl Mix.Task
  def run(argv) do
    {own, passthrough} = CLI.split_passthrough(argv)

    if CLI.prescan(own) == [] do
      CLI.help("composer.step.run")
    else
      CLI.require_project!()
      Process.put({__MODULE__, :passthrough}, passthrough)
      super(own)
    end
  end

  # Composed runs (Igniter.compose_task/3) never go through run/1, so the
  # pass-through is split off here too.
  @impl Igniter.Mix.Task
  def parse_argv(argv) do
    {own, passthrough} = CLI.split_passthrough(argv)

    passthrough =
      if passthrough == [], do: Process.get({__MODULE__, :passthrough}, []), else: passthrough

    %{super(own) | argv: own ++ ["--" | passthrough]}
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    refs =
      case igniter.args.positional[:refs] do
        nil -> Mix.raise("Usage: mix composer.step.run REF[,REF...] [-- ARGS]")
        refs -> refs |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    {_own, passthrough} = CLI.split_passthrough(igniter.args.argv)
    cookbooks = CLI.cookbooks!()

    entries =
      CLI.ok!(
        Resolver.resolve_steps(cookbooks, refs,
          context: CLI.context(cookbooks),
          argv: passthrough
        )
      )

    CLI.ok!(Preflight.check(entries))
    runner = Application.get_env(:composer, :runner, Composer.Runner)

    entries
    |> Resolver.warnings()
    |> Enum.reduce(igniter, &Igniter.add_warning(&2, Error.warning(&1)))
    |> runner.run(Resolver.steps(entries), [])
  end
end
