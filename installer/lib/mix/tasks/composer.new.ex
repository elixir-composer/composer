defmodule Mix.Tasks.Composer.New do
  @shortdoc "Creates an Elixir app and applies a composer recipe"

  @moduledoc """
  Creates an app with `igniter.new`, installs composer and a cookbook,
  records the command line as the first commit, and runs a recipe.

      mix composer.new APP [REF] [RECIPE-FLAGS] [OPTIONS]

      mix composer.new my_app cb_std/completions/install --with phx.new --with-args=--no-ecto
      mix composer.new my_app cb_lab/lv/base@github:elixir-composer/cb_lab@v0.3.0
      mix composer.new my_app cb_home/lv/base@path:~/src/Gen/cb_home --with phx.new
      mix composer.new my_app cb_mine/phx/saas --oban-pro --gigalixir

  ## REF

  `COOKBOOK/CHAPTER/RECIPE[@SOURCE]`, where SOURCE says where the cookbook
  comes from, as in `mix igniter.install`:

    * none - the latest Hex release
    * a version requirement, `@~> 0.3` or `@>= 0.3.1`, kept as written
    * a version, `@0.3.1` (`== 0.3.1`) or `@0.3` (`~> 0.3`)
    * `@github:OWNER/REPO`, or `@github:OWNER/REPO@GITREF`
    * `@git:URL`
    * `@path:PATH`

  REF is a qualified recipe address: root (`/lv/base`), relative
  (`./base`) and bare (`base`) addresses are rejected, as are steps and
  `hex:` packages. `cb_std/CHAPTER/RECIPE` takes no source, since `cb_std`
  ships with composer. Without a REF, the app gets composer only: run
  `mix composer.init` in it to start your own cookbook.

  ## Options

    * `--with TASK` - the base generator, as in `igniter.new` (`phx.new`,
      ...); default `new`
    * `--with-args ARGS` - arguments for `--with`. Prefer the `=` form:
      `--with-args="--no-ecto --binary-id"`
    * `--install PKG[,PKG]` - base packages installed with the app, as
      prod deps (repeatable); `PKG[@SOURCE]`, with SOURCE as in REF
    * `--composer SOURCE` - where composer comes from (`path:...`,
      `github:...`, a version); default `~> MAJOR.MINOR` of this archive's
      version
    * `--extra-dep PKG` - another dev/test dep, such as a second cookbook
      (repeatable); `PKG[@SOURCE]`, as `--install`
    * `--igniter-local PATH` - a local igniter checkout, passed to
      `igniter.new --local` relative to the app's parent directory
    * `--reset` - delete APP first
    * `--dry-run` - print the plan and run nothing
    * `--no-recipe` - create, install and commit, but don't run the recipe

  Every other switch is a recipe flag, passed on to
  `mix composer.recipe.run`, which rejects any the recipe doesn't
  declare. Everything after `--` is a recipe flag too. There is no
  `--yes`: the command runs unattended.

  ## What it runs

  The plan is printed first, every time; `--dry-run` stops there.

    1. `mix igniter.new APP --no-git --yes ...`, with `--with`,
       `--with-args` and `--local`
    2. in APP, `mix composer_new.install PKG,... --yes`, for `--install`
    3. in APP, `mix composer_new.install composer,COOKBOOK,... --only dev,test --yes`
    4. in APP, `git init`, `git add -A` and `git commit`, with this command
       line as the message: `git log --reverse` shows how to rebuild the app
    5. in APP, `mix composer.recipe.run COOKBOOK/CHAPTER/RECIPE [RECIPE-FLAGS]`,
       unless there is no REF or `--no-recipe` is given

  `mix composer_new.install`, which this archive provides, is
  `mix igniter.install` taking SOURCE as REF does: `igniter.install`
  rejects a version requirement such as `~> 0.3`, and this writes it to
  `mix.exs` as given.

  ## Recovery

  The run stops at the first command that fails. If steps 1 to 3 fail, APP
  is partial: fix the problem and rerun with `--reset`. If the recipe
  fails, APP is left at its generation commit, and the exact
  `cd APP && mix composer.recipe.run ...` to retry is printed.

  ## A recipe is code

  A cookbook from `@github:` or `@git:` runs someone else's code on your
  machine, as `igniter.new --install` does. To look first, pass
  `--no-recipe`, then run `mix composer.recipe.show REF` and
  `mix composer.recipe.run REF --dry-run` in the app.
  """

  use Mix.Task

  alias ComposerNew.{Command, Plan, Preflight, Shell}

  @version Mix.Project.config()[:version]

  @impl Mix.Task
  def run(argv) do
    if argv == [] or (Enum.any?(argv, &(&1 in ["--help", "-h"])) and "--" not in argv) do
      Mix.Task.run("help", ["composer.new"])
    else
      new(argv)
    end
  end

  defp new(argv) do
    env = %{cwd: File.cwd!(), home: System.user_home!(), version: @version}

    plan =
      case Plan.build(argv, env) do
        {:ok, plan} -> plan
        {:error, message} -> fail!(message)
      end

    Shell.print(plan)

    case Preflight.check(plan) do
      {:ok, warnings} ->
        Enum.each(warnings, &Mix.shell().info([:yellow, "warning: ", &1, :reset]))

      {:error, problems} ->
        fail!(
          "Preflight checks failed, so nothing was run:\n\n" <>
            Enum.map_join(problems, "\n", &("  * " <> &1))
        )
    end

    if plan.parsed.opts[:dry_run] do
      Mix.shell().info("\nDry run: nothing was run.")
    else
      case Shell.run(plan) do
        :ok -> Mix.shell().info([:green, "\nCreated #{plan.summary.dir}.", :reset])
        {:error, command, status} -> fail!(failure(plan, command, status))
      end
    end
  end

  defp failure(plan, %Command{label: label} = command, status) do
    dir = plan.summary.dir
    failed = "#{Command.to_string(command)} failed (exit status #{status})."

    case label do
      :run ->
        "#{failed}\n\n#{dir} is at its generation commit. To retry the recipe:\n\n" <>
          "    cd #{Command.escape(dir)} && #{Command.to_string(command)}"

      :install ->
        # Quotes the lockstep default (see the checklist in installer/mix.exs).
        hint =
          if plan.summary.default_composer?,
            do:
              "\n\nIf composer #{Plan.default_composer(@version)} isn't on Hex, " <>
                "point at a checkout with " <>
                "--composer path:/path/to/composer.",
            else: ""

        "#{failed}\n\n#{dir} is partial; rerun with --reset." <> hint

      :create ->
        "#{failed}\n\n#{dir} is partial; rerun with --reset."

      :record ->
        "#{failed}\n\nThe app is installed but not committed: commit in #{dir} by hand, " <>
          "or rerun with --reset."
    end
  end

  defp fail!(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
