defmodule Composer.Runner do
  @moduledoc """
  Runs a resolved step list against an igniter.

  The list comes from `Composer.Resolver`, already expanded and filtered by
  flags, so every step here runs. Each step is one of:

    * `{:module, module}` - compose a step (any Igniter task module)
    * `{:module, module, argv}` - the same, with arguments
    * `{:install, package, opts}` - add a package and run its installer
    * `{:task, task, argv}` - compose an Igniter-aware Mix task by name
    * `{:queue, task, argv}` - queue a Mix task to run after the changes apply

  Steps apply in list order, and every change lands in one diff. The one
  exception is dependencies: packages to install are added to `mix.exs` and
  fetched before any step runs, because their installers have to be on
  disk to compose. Queued tasks run last, non-interactively with `--yes`.

  ## The install step

  `{:install, package, opts}` is internal: `Composer.Resolver` builds it
  from `hex:` references, and recipes always write `"hex:pkg"` or
  `{"hex:pkg", opts}`, never `{:install, ...}`. `opts` is a canonical
  keyword list, so two installs with the same options are equal; keys come
  in this order, and empty ones are left out:

    * `argv` - arguments for the package's installer
    * `source` - where the package comes from: `[version: requirement]`,
      `[path: path]`, or `[github: "owner/repo"]` / `[git: url]` followed
      by git options (`ref`, `branch`, `tag`, `sparse`, `submodules`)
      sorted by key. Without one, the latest Hex version is used.
    * `dep` - `only` (a sorted list of atoms) and `runtime`, merged into
      the dependency

  Every install is added and fetched up front, with one fetch for all of
  them, then its installer, if it ships one, runs at the step's position
  with `argv` plus `--yes`. A `path` source adds `override: true`. The
  runner trusts its input: given two installs of one package, the first
  one's dependency wins.
  """

  # Composer supports only the latest stable Phoenix. The check version is a
  # sentinel meaning "any release in the supported series": an app requirement
  # like "~> 1.8.8" admits 1.8.99, while "~> 1.7.0" does not.
  @supported_phoenix_series "1.8"
  @phoenix_check_version "1.8.99"

  # Igniter runs queued tasks via Mix.shell().cmd, which has no stdin — a
  # prompting subprocess would stall forever waiting for input that can
  # never arrive, so queued tasks always run with --yes (confirming the
  # run is the approval for what it queues). Nothing else is forwarded:
  # recipe flags have already done their job selecting steps, and leaking
  # them crashes queued tasks with strict option parsers.
  @queued_flags ["--yes"]

  @type step ::
          {:module, module()}
          | {:module, module(), [String.t()]}
          | {:install, atom(), keyword()}
          | {:task, String.t(), [String.t()]}
          | {:queue, String.t(), [String.t()]}

  @doc """
  Runs `steps` in order.

  Warns when the target app's Phoenix requirement is older than the
  supported series (#{@supported_phoenix_series}).
  """
  @spec run(Igniter.t(), [step()], keyword()) :: Igniter.t()
  def run(igniter, steps, _opts \\ []) when is_list(steps) do
    igniter
    |> check_phoenix_version()
    |> prepare_installs(steps)
    |> show_plan(steps)
    |> then(&Enum.reduce(steps, &1, fn step, igniter -> apply_step(igniter, step) end))
  end

  @doc """
  Returns the packages `steps` install, in order.

  These are added to `mix.exs` and fetched before any step runs, so this is
  the set whose dependency changes reach disk ahead of the run's diff.
  """
  @spec installs([step()]) :: [atom()]
  def installs(steps), do: for({:install, package, _opts} <- steps, uniq: true, do: package)

  @doc false
  # The label of an install, shared by the resolver's entries and the plan.
  @spec install_label(String.t() | atom(), keyword()) :: String.t()
  def install_label(package, opts) do
    source =
      case Keyword.get(opts, :source, []) do
        [] ->
          []

        [{kind, value} | git_opts] ->
          details = Enum.map(git_opts, fn {key, v} -> "#{key} #{v}" end)
          ["(" <> Enum.join(["#{kind} #{value}" | details], ", ") <> ")"]
      end

    Enum.join(["hex:#{package}" | source] ++ Keyword.get(opts, :argv, []), " ")
  end

  @doc false
  # The dependency for an install with a source, or nil when the latest
  # Hex version is to be looked up. Pure, so it can be tested offline.
  @spec dep_spec(String.t(), keyword()) :: tuple() | nil
  def dep_spec(package, opts) do
    {name, repo} =
      case String.split(package, ".", parts: 2) do
        [repo, name] -> {name, [repo: repo]}
        [name] -> {name, []}
      end

    # Package names come from recipes and the command line, which the user
    # controls; a dependency needs an atom.
    name = String.to_atom(name)

    case Keyword.get(opts, :source, []) do
      [] -> nil
      [version: requirement] when repo == [] -> {name, requirement}
      [version: requirement] -> {name, requirement, repo}
      [path: path] -> {name, path: path, override: true}
      [{kind, _} | _] = git when kind in [:github, :git] -> {name, git}
    end
  end

  @doc false
  # Folds only:/runtime: into a dependency tuple of any shape.
  @spec merge_dep_opts(tuple(), keyword()) :: tuple()
  def merge_dep_opts(dep, []), do: dep

  def merge_dep_opts(dep, dep_opts) do
    dep_opts =
      case dep_opts[:only] do
        [env] -> Keyword.put(dep_opts, :only, env)
        _ -> dep_opts
      end

    case dep do
      {name, opts} when is_list(opts) -> {name, opts ++ dep_opts}
      {name, requirement} -> {name, requirement, dep_opts}
      {name, requirement, opts} -> {name, requirement, opts ++ dep_opts}
    end
  end

  # Printed after the dependency fetch, because which packages ship an
  # installer is only knowable once they are on disk. This is where a reader
  # sees what each step resolved to and what defers.
  defp show_plan(igniter, steps) do
    if igniter.assigns[:test_mode?] do
      igniter
    else
      Mix.shell().info(["\n", IO.ANSI.bright(), "Composer plan", IO.ANSI.reset()])
      Enum.each(steps, &Mix.shell().info("  #{describe(&1)}"))
      Mix.shell().info("")
      igniter
    end
  end

  defp describe({:module, module}), do: label(module)
  defp describe({:module, module, argv}), do: Enum.join([label(module) | argv], " ")
  defp describe({:task, task, _argv}), do: task

  defp describe({:install, package, opts}) do
    case installer(package) do
      nil -> "#{install_label(package, opts)} — dependency only, ships no installer"
      task -> "#{install_label(package, opts)} — #{task}"
    end
  end

  defp describe({:queue, task, _argv}), do: "#{task} — queued, runs after this run applies"

  defp label(module) do
    if function_exported?(module, :__composer_step__, 0),
      do: module.__composer_step__().ref,
      else: inspect(module)
  end

  # Adds every {:install, ...} package to mix.exs and fetches once, before any
  # step runs. Igniter writes only the deps change to disk here, leaving the
  # rest of the run's diff pending — which is what lets the installers composer
  # into this run instead of being queued into a subprocess.
  defp prepare_installs(igniter, steps) do
    case for {:install, package, opts} <- steps, do: {package, opts}, uniq: true do
      [] ->
        igniter

      installs ->
        installs = Enum.uniq_by(installs, &elem(&1, 0))
        packages = Enum.map(installs, &elem(&1, 0))

        # Resolving versions queries Hex and apply_and_fetch_dependencies/2
        # raises in test mode, so installs are inert under Igniter.Test: no
        # installer resolves and each step no-ops.
        if igniter.assigns[:test_mode?] do
          igniter
        else
          installs
          |> Enum.reduce(igniter, &add_install_dep(&2, &1))
          |> Igniter.apply_and_fetch_dependencies(
            operation: "compiling #{Enum.join(packages, ", ")}",
            yes: "--yes" in argv(igniter),
            yes_to_deps: "--yes-to-deps" in argv(igniter)
          )
        end
    end
  end

  # A dep already in mix.exs is overwritten, as Igniter does.
  defp add_install_dep(igniter, {package, opts}) do
    package = to_string(package)

    dep =
      dep_spec(package, opts) ||
        Igniter.Project.Deps.determine_dep_type_and_version!(package, argv: argv(igniter))

    Igniter.Project.Deps.add_dep(igniter, merge_dep_opts(dep, Keyword.get(opts, :dep, [])))
  end

  defp argv(igniter) do
    case igniter.args do
      %{argv: argv} when is_list(argv) -> argv
      _ -> []
    end
  end

  defp check_phoenix_version(igniter) do
    if igniter.assigns[:composer_phoenix_checked] do
      igniter
    else
      igniter = Igniter.assign(igniter, :composer_phoenix_checked, true)

      with {:ok, declaration} when is_binary(declaration) <-
             Igniter.Project.Deps.get_dep(igniter, :phoenix),
           {:ok, requirement} when is_binary(requirement) <- extract_requirement(declaration),
           {:ok, _} <- Version.parse_requirement(requirement),
           false <- Version.match?(@phoenix_check_version, requirement) do
        Igniter.add_warning(igniter, """
        This app depends on phoenix #{inspect(requirement)}, but Composer supports only \
        the latest stable Phoenix (#{@supported_phoenix_series}). Steps may not apply cleanly.
        """)
      else
        _ -> igniter
      end
    end
  end

  defp extract_requirement(declaration) do
    case Code.string_to_quoted(declaration) do
      {:ok, {_name, requirement}} -> {:ok, requirement}
      {:ok, {:{}, _, [_name, requirement | _]}} -> {:ok, requirement}
      _ -> :error
    end
  end

  defp apply_step(igniter, {:module, module}), do: Igniter.compose_task(igniter, module)

  defp apply_step(igniter, {:module, module, argv}),
    do: Igniter.compose_task(igniter, module, argv)

  defp apply_step(igniter, {:task, task, argv}) do
    Igniter.compose_task(igniter, task, argv, fn igniter ->
      Igniter.add_warning(igniter, """
      Step {:task, #{inspect(task)}} was skipped: `mix #{task}` is not an \
      Igniter task, so it cannot be composed into this run. Run it \
      directly instead, or use {:queue, #{inspect(task)}, [...]}: \
      mix #{task} #{Enum.join(argv, " ")}
      """)
    end)
  end

  # The dep is already added and fetched by prepare_installs/2, so all that is
  # left is the package's own installer, if it ships one. Composing it here
  # puts its changes in this run's diff, at this position in the step list.
  defp apply_step(igniter, {:install, package, opts}) do
    argv = Keyword.get(opts, :argv, [])

    igniter =
      case installer(package) do
        nil when argv != [] ->
          Igniter.add_warning(igniter, """
          hex:#{package} ships no installer, so its argv \
          (#{Enum.join(argv, " ")}) was not used. Remove argv: from the \
          hex:#{package} entry.
          """)

        nil ->
          igniter

        # With explicit argv, compose_task/3 parses only that argv and
        # inherits nothing from this run, so --yes is passed here, once.
        task ->
          Igniter.compose_task(
            igniter,
            task,
            if("--yes" in argv, do: argv, else: argv ++ ["--yes"])
          )
      end

    patch_install(igniter, package)
  end

  defp apply_step(igniter, {:queue, task, argv}) do
    Igniter.add_task(igniter, task, argv ++ @queued_flags)
  end

  # A private-repo package (org.pkg) ships its installer as pkg.install.
  defp installer(package) do
    name = package |> to_string() |> String.split(".") |> List.last()
    Mix.Task.get("#{name}.install") && "#{name}.install"
  end

  # oban_web's installer wires up the router but doesn't add itself to
  # import_deps, so its formatter directives never run without this. It also
  # writes the oban_dashboard call with parens; `mix format` never strips
  # parens from a call that already has them (only ever adds missing ones),
  # so being in import_deps from here on doesn't retroactively fix this run's
  # router — the call is rewritten directly instead.
  defp patch_install(igniter, :oban_web) do
    igniter
    |> Igniter.Project.Formatter.import_dep(:oban_web)
    |> drop_oban_dashboard_parens()
  end

  defp patch_install(igniter, _package), do: igniter

  defp drop_oban_dashboard_parens(igniter) do
    app_name = Igniter.Project.Application.app_name(igniter)
    path = "lib/#{app_name}_web/router.ex"

    if Igniter.exists?(igniter, path) do
      Composer.Edit.Files.update(igniter, path, fn content ->
        String.replace(content, ~r/oban_dashboard\((.+)\)(\s*)$/m, "oban_dashboard \\1\\2")
      end)
    else
      igniter
    end
  end
end
