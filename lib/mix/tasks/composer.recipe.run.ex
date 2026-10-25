defmodule Mix.Tasks.Composer.Recipe.Run do
  @shortdoc "Resolves and runs a recipe, then commits the result"

  @moduledoc """
  Resolves a recipe and applies it to the current app as one diff, then
  records the run as one git commit.

      mix composer.recipe.run /app/default
      mix composer.recipe.run my_app/phx/app --gigalixir --oban-pro
      mix composer.recipe.run /app/default --dry-run
      mix composer.recipe.run /app/default --no-commit

  The recipe is addressed as `cookbook/chapter/name`, or `/chapter/name`
  in the current project's cookbook; a bare name (`default`) searches
  every cookbook for the one recipe whose name it is.
  `mix composer.recipe.list` lists them.

  Every flag declared in the `flags:` of the recipe, or of a recipe it
  includes, becomes a `--flag` option; `mix composer.recipe.show RECIPE`
  shows them. Any other `--flag` is rejected.

  Before anything runs, every reference is resolved and the steps'
  `requires` are checked; a missing executable or an incompatible package
  version stops the run.

  ## Git commit

  Unless `--no-commit` is given, the run:

    1. refuses to start if the app is not inside a git work tree, or if the
       tree has uncommitted, unstaged or untracked changes. This is checked
       before anything is written, including the dependency fetch;
    2. applies the steps as one diff, without asking (see below);
    3. commits everything with `git add -A` and a message listing the
       flags and every step with the recipe it came from.

  The commit is a queued task, so it runs last, after any `{:queue, ...}`
  steps, and only if the diff is applied. `--dry-run` commits nothing.

  ## Unattended runs

  The run always acts as if `--yes` were given: it applies the diff and
  fetches dependencies without asking, so it goes through unattended. The
  diff isn't shown; use `--dry-run` to preview it first (a dry run doesn't
  add `--yes`, since Igniter hides the diff under it).

  ## Options

    * `--no-commit` - skip the git checks and the commit
    * `--dry-run` - as for any Igniter task
    * `--yes` - implied unless `--dry-run` is given
  """

  use Igniter.Mix.Task

  alias Composer.{CLI, Error, Git, Preflight, Resolver}

  @base_schema [no_commit: :boolean]

  @impl Igniter.Mix.Task
  def info(argv, _composing_task) do
    flag_schema =
      case CLI.prescan(argv) do
        [recipe | _] ->
          cookbooks = CLI.cookbooks!()
          result = CLI.resolve_recipe!(cookbooks, recipe, :all)
          flags = result |> Resolver.declared_flags() |> Keyword.keys()

          if flag = Enum.find(flags, &(&1 in Composer.Recipe.reserved_flags())) do
            Mix.raise(Error.message({:reserved_flag, flag}))
          end

          schema = Enum.map(flags, &{&1, :boolean})
          CLI.check_switches!(argv, @base_schema ++ schema, [], result.root, flags)
          schema

        [] ->
          []
      end

    %Igniter.Mix.Task.Info{
      positional: [:recipe],
      schema: @base_schema ++ flag_schema,
      example: "mix composer.recipe.run /app/default --gigalixir"
    }
  end

  # Always run as if --yes were given, so runs go through unattended. It goes
  # into argv, not just the options, because the runner's dep fetch reads
  # argv. A dry run is left alone: under --yes Igniter doesn't print the diff.
  @impl Mix.Task
  def run(argv) do
    CLI.require_project!()

    if Enum.any?(argv, &(&1 in ["--yes", "--dry-run"])),
      do: super(argv),
      else: super(argv ++ ["--yes"])
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    commit? = not Keyword.get(opts, :no_commit, false)
    cookbooks = CLI.cookbooks!()

    # Validate every include, gated or not, before anything runs.
    all = CLI.resolve_recipe!(cookbooks, igniter.args.positional.recipe, :all)
    result = CLI.resolve_recipe!(cookbooks, all.root, opts)
    active = Resolver.active(result.steps, opts)

    CLI.ok!(Preflight.check(active))
    if commit?, do: check_git!()

    runner = runner()

    igniter =
      active
      |> Resolver.warnings()
      |> Enum.reduce(igniter, &Igniter.add_warning(&2, Error.warning(&1)))
      |> runner.run(Resolver.steps(active), opts)

    if commit? do
      flags = Enum.filter(Resolver.flags(all), &(Keyword.get(opts, &1) == true))
      message = Git.message(result.root, %{flags: flags}, active)

      file = write_message!(message, Keyword.get(opts, :dry_run, false))
      Igniter.add_task(igniter, "composer.git.commit", ["--message-file", file])
    else
      igniter
    end
  end

  # Tests swap in a runner that records the steps instead of applying them.
  defp runner, do: Application.get_env(:composer, :runner, Composer.Runner)

  defp check_git! do
    case Git.status(File.cwd!()) do
      :clean ->
        :ok

      :not_a_repo ->
        Mix.raise("""
        This app is not inside a git repository, so the run can't be committed.

        Create one first:

            git init && git add -A && git commit -m "Initial commit"

        or pass --no-commit to run without committing.
        """)

      :dirty ->
        Mix.raise("""
        The git work tree has uncommitted changes, which would be mixed into
        the run's commit.

        Commit or stash them first (see `git status`), or pass --no-commit to
        run without committing.
        """)
    end
  end

  # The commit task deletes the file, but it never runs on a dry run, a
  # declined diff, or after a failed queued task. Dry runs don't write the
  # file at all, and files left behind by earlier runs are swept here.
  @message_glob "composer-commit-*.txt"
  @stale_after_seconds 3600

  defp write_message!(message, dry_run?) do
    tmp = System.tmp_dir!()
    sweep_stale_messages(tmp)

    name =
      String.replace(
        @message_glob,
        "*",
        "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
      )

    path = Path.join(tmp, name)
    unless dry_run?, do: File.write!(path, message)
    shell_arg(path)
  end

  defp sweep_stale_messages(tmp) do
    cutoff = System.os_time(:second) - @stale_after_seconds

    tmp
    |> Path.join(@message_glob)
    |> Path.wildcard()
    |> Enum.each(fn file ->
      case File.stat(file, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime < cutoff -> File.rm(file)
        _ -> :ok
      end
    end)
  end

  # Igniter runs queued tasks through the shell with args joined by spaces.
  defp shell_arg(path) do
    if path =~ ~r{\A[\w/.\-]+\z},
      do: path,
      else: "'" <> String.replace(path, "'", ~S('\'')) <> "'"
  end
end
