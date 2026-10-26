defmodule Mix.Tasks.Composer.New do
  @shortdoc "Creates an Elixir app and applies a composer recipe"

  @moduledoc """
  Creates an app with `igniter.new`, installs composer and cookbooks,
  records the command line as the first commit, and runs a recipe.

      mix composer.new APP [--cookbook PKG]... [--recipe REF [--recipe-args ARGS]] [OPTIONS]

      mix composer.new my_app --recipe cb_std/completions/install \\
        --with phx.new --with-args=--no-ecto
      mix composer.new my_app --cookbook cb_lab@github:elixir-composer/cb_lab@v0.3.0 \\
        --recipe cb_lab/lv/base
      mix composer.new my_app --cookbook cb_home@path:~/src/Gen/cb_home \\
        --recipe cb_home/lv/base --with phx.new
      mix composer.new my_app --recipe cb_mine/phx/saas --recipe-args="--oban-pro --gigalixir"

  Without `--recipe`, the app gets composer and the `--cookbook`s only:
  run a recipe in it later, or `mix composer.init` to start your own
  cookbook.

  ## Cookbooks

  `--cookbook PKG[@SOURCE]` installs a cookbook as a dev/test dep, and may
  be repeated. SOURCE says where it comes from, as in
  `mix igniter.install`:

    * none - the latest Hex release
    * a version requirement, `@~> 0.3` or `@>= 0.3.1`, kept as written
    * a version, `@0.3.1` (`== 0.3.1`) or `@0.3` (`~> 0.3`)
    * `@github:OWNER/REPO`, or `@github:OWNER/REPO@GITREF`
    * `@git:URL`
    * `@path:PATH`

  `cb_std` ships with composer, so it is never given here.

  ## Recipe

  `--recipe COOKBOOK/CHAPTER/RECIPE` is the recipe to run, at most one.
  Root (`/lv/base`), relative (`./base`) and bare (`base`) addresses are
  rejected, as are steps and `hex:` packages. A recipe takes no
  `@SOURCE`: its cookbook is

    * `cb_std`, which ships with composer, or
    * a `--cookbook` of that name, or
    * an `--install` package of that name: a framework that bundles its
      cookbook (see composer's Bundling guide), or else
    * the latest Hex release of that name. If there is no such package on
      Hex, preflight fails before anything is created.

  `--recipe-args ARGS` are the recipe's flags, one string split as a shell
  would (`--recipe-args="--oban-pro --title 'My App'"`), passed on to
  `mix composer.recipe.run`, which rejects any the recipe doesn't
  declare. If the cookbook has no such recipe, `mix composer.recipe.run`
  fails too, after the app is committed.

  ## Options

    * `--with TASK` - the base generator, as in `igniter.new` (`phx.new`,
      ...); default `new`
    * `--with-args ARGS` - arguments for `--with`. Prefer the `=` form:
      `--with-args="--no-ecto --binary-id"`
    * `--install PKG[,PKG]` - base packages installed with the app, as
      prod deps (repeatable); `PKG[@SOURCE]`, with SOURCE as in
      `--cookbook`
    * `--cookbook PKG` - a cookbook (repeatable); see above
    * `--recipe REF` - the recipe to run; see above
    * `--recipe-args ARGS` - the recipe's flags; needs `--recipe`
    * `--composer SOURCE` - where composer comes from (`path:...`,
      `github:...`, a version); default `~> MAJOR.MINOR` of this archive's
      version
    * `--igniter-local PATH` - a local igniter checkout, passed to
      `igniter.new --local` relative to the app's parent directory
    * `--reset` - delete APP first
    * `--dry-run` - print the plan and run nothing

  Any other switch is an error. Options other than `--install` and
  `--cookbook` may be given once. There is no `--yes`:
  the command runs unattended.

  ## What it runs

  The plan is printed first, every time; `--dry-run` stops there.

    1. `mix igniter.new APP --no-git --yes ...`, with `--with`,
       `--with-args` and `--local`
    2. in APP, `mix composer_new.install composer,COOKBOOK,... --only dev,test --yes`
    3. in APP, `mix composer_new.install PKG,... --yes`, for `--install`;
       after composer, so a framework that bundles a cookbook compiles
       with composer present
    4. in APP, `git init`, `git add -A` and `git commit`, with this command
       line as the message: `git log --reverse` shows how to rebuild the app
    5. in APP, `mix composer.recipe.run COOKBOOK/CHAPTER/RECIPE [RECIPE-ARGS]`,
       with `--recipe`

  `mix composer_new.install`, which this archive provides, is
  `mix igniter.install` taking SOURCE as `--cookbook` does:
  `igniter.install` rejects a version requirement such as `~> 0.3`, and
  this writes it to `mix.exs` as given.

  ## Recovery

  The run stops at the first command that fails. If steps 1 to 3 fail, APP
  is partial: fix the problem and rerun with `--reset`. If the recipe
  fails, APP is left at its generation commit, and the exact
  `cd APP && mix composer.recipe.run ...` to retry is printed.

  ## A recipe is code

  A cookbook from `@github:` or `@git:` runs someone else's code on your
  machine, as `igniter.new --install` does. To look first, give the
  `--cookbook` without `--recipe`, then run `mix composer.recipe.show REF`
  and `mix composer.recipe.run REF --dry-run` in the app.
  """

  use Mix.Task

  alias ComposerNew.{Argv, Command, Plan, Preflight, Shell}

  @version Mix.Project.config()[:version]

  @impl Mix.Task
  def run(argv) do
    if argv == [] or Argv.help?(argv) do
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
