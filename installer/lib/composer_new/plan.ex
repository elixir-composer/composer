defmodule ComposerNew.Plan do
  @moduledoc """
  Turns `mix composer.new` argv into the list of commands to run.

  `build/2` is pure: everything it needs from the outside (the working
  directory, the home directory, the archive's version) comes in `env`,
  so `--dry-run` prints exactly what a run executes, and the tests check
  the same lists. The commands, in order (`[...]` is optional):

      rm -rf APP                                              (--reset)
      mix igniter.new APP --no-git --yes [--local REL] [--with TASK]
          [--with-args=ARGS]
      (in APP) mix composer_new.install PKG,... --yes      (--install PKG,...)
      (in APP) mix composer_new.install composer@SRC[,COOKBOOK[@SRC]][,EXTRA,...]
          --only dev,test --yes
      (in APP) git init
      (in APP) git add -A
      (in APP) git commit -m "mix composer.new <argv as typed>"
      (in APP) mix composer.recipe.run COOKBOOK/CHAPTER/RECIPE [FLAGS]
                                               (REF given, no --no-recipe)

  `igniter.new` gets `--no-git`, so the history starts with the commit
  above rather than with igniter's own. `git init` is harmless in a repo
  the base generator already made, so it is always planned.

  Packages go through `mix composer_new.install`, not `mix igniter.install`
  (or `igniter.new --install`), so a version requirement such as `~> 0.3`
  reaches `mix.exs` as written; see `Mix.Tasks.ComposerNew.Install`.

  `path:` sources are made absolute, since the install runs inside APP.
  The commit message keeps the argv as typed.
  """

  alias ComposerNew.{Argv, Command, Dep, Ref}

  @enforce_keys [:summary, :commands, :parsed]
  defstruct [:summary, :commands, :parsed]

  @type env :: %{cwd: Path.t(), home: Path.t(), version: String.t()}
  @type step :: Command.t() | {:rm_rf, Path.t()}
  @type t :: %__MODULE__{summary: map(), commands: [step()], parsed: Argv.t()}

  @app_name ~r/\A[a-z][a-z0-9_]*\z/

  @doc "Builds the plan for `argv`."
  @spec build([String.t()], env()) :: {:ok, t()} | {:error, String.t()}
  def build(argv, env) do
    with {:ok, parsed} <- Argv.parse(argv),
         {:ok, ref} <- parse_ref(parsed.ref),
         {:ok, composer} <- composer_spec(parsed.opts[:composer], env),
         {:ok, install} <- packages(parsed.opts[:install], "--install", env),
         {:ok, extra} <- packages(parsed.opts[:extra_dep], "--extra-dep", env),
         :ok <- check_app(parsed.app) do
      {:ok, plan(argv, parsed, ref, %{composer: composer, install: install, extra: extra}, env)}
    end
  end

  defp parse_ref(nil), do: {:ok, nil}
  defp parse_ref(string), do: Ref.parse(string)

  @doc """
  The composer requirement an app gets without `--composer`: this
  archive's major and minor version, as `~> MAJOR.MINOR`.

      iex> ComposerNew.Plan.default_composer("0.3.1")
      "~> 0.3"
  """
  @spec default_composer(String.t()) :: String.t()
  def default_composer(version) do
    %Version{major: major, minor: minor} = Version.parse!(version)
    "~> #{major}.#{minor}"
  end

  # Relies on composer and composer_new sharing a version; to split
  # versions, see the checklist in installer/mix.exs.
  defp composer_spec(nil, env), do: {:ok, "composer@" <> default_composer(env.version)}

  defp composer_spec(spec, env) do
    case Ref.parse_source(spec) do
      {:ok, _source} -> {:ok, Ref.install_spec("composer", spec, env)}
      {:error, message} -> {:error, "--composer: " <> message}
    end
  end

  defp packages(strings, option, env) do
    Enum.reduce_while(strings, {:ok, []}, fn string, {:ok, acc} ->
      case Dep.parse(string) do
        {:ok, _dep} -> {:cont, {:ok, acc ++ [Ref.expand_package(string, env)]}}
        {:error, message} -> {:halt, {:error, "#{option}: " <> message}}
      end
    end)
  end

  defp check_app(app) do
    name = Path.basename(app)

    if Regex.match?(@app_name, name),
      do: :ok,
      else:
        {:error,
         "#{inspect(name)} is not a valid app name: it must start with a lowercase letter " <>
           "and have only lowercase letters, digits and underscores"}
  end

  defp plan(argv, parsed, ref, packages, env) do
    opts = parsed.opts

    app_arg =
      if String.starts_with?(parsed.app, "~"), do: Ref.expand(parsed.app, env), else: parsed.app

    dir = Ref.expand(app_arg, env)
    install = packages.install
    deps = [packages.composer | List.wrap(cookbook_spec(ref, env))] ++ packages.extra

    recipe = if ref && not opts[:no_recipe], do: Ref.recipe(ref)

    create =
      ["igniter.new", app_arg, "--no-git", "--yes"] ++
        local(opts[:igniter_local], dir, env) ++
        if(opts[:with], do: ["--with", opts[:with]], else: []) ++
        if(opts[:with_args], do: ["--with-args=" <> opts[:with_args]], else: [])

    commands =
      if(opts[:reset], do: [{:rm_rf, dir}], else: []) ++
        [
          %Command{label: :create, cmd: "mix", args: create}
        ] ++
        if(install != [],
          do: [
            %Command{
              label: :install,
              cmd: "mix",
              args: ["composer_new.install", Enum.join(install, ","), "--yes"],
              cd: dir
            }
          ],
          else: []
        ) ++
        [
          %Command{
            label: :install,
            cmd: "mix",
            args: ["composer_new.install", Enum.join(deps, ","), "--only", "dev,test", "--yes"],
            cd: dir
          },
          %Command{label: :record, cmd: "git", args: ["init", "--quiet"], cd: dir},
          %Command{label: :record, cmd: "git", args: ["add", "-A"], cd: dir},
          %Command{
            label: :record,
            cmd: "git",
            args: ["commit", "--quiet", "-m", message(argv)],
            cd: dir
          }
        ] ++
        if(recipe,
          do: [
            %Command{
              label: :run,
              cmd: "mix",
              args: ["composer.recipe.run", recipe | parsed.recipe_flags],
              cd: dir
            }
          ],
          else: []
        )

    summary = %{
      app: Path.basename(dir),
      dir: dir,
      cookbook: ref && ref.cookbook,
      source: source(ref),
      recipe: recipe,
      base: base(opts),
      install: install,
      deps: deps,
      default_composer?: opts[:composer] == nil
    }

    %__MODULE__{summary: summary, commands: commands, parsed: parsed}
  end

  # A cb_std/ recipe needs no cookbook install: cb_std ships with composer.
  defp cookbook_spec(nil, _env), do: nil
  defp cookbook_spec(%{cookbook: "cb_std"}, _env), do: nil
  defp cookbook_spec(ref, env), do: Ref.install_spec(ref.cookbook, ref.spec, env)

  # igniter.new writes `path: Path.join("..", local)` into the app's mix.exs,
  # so --local must be relative to the app's parent directory.
  defp local(nil, _dir, _env), do: []

  defp local(path, dir, env) do
    target = Ref.expand(path, env)
    ["--local", Path.relative_to(target, Path.dirname(dir), force: true)]
  end

  defp message(argv), do: Command.join(["mix", "composer.new" | argv])

  defp source(nil), do: nil
  defp source(%{cookbook: "cb_std"}), do: "ships with composer"
  defp source(%{spec: nil}), do: "hex, latest"
  defp source(%{spec: spec}), do: spec

  defp base(opts) do
    with_args = if opts[:with_args], do: " " <> opts[:with_args], else: ""
    (opts[:with] || "new") <> with_args
  end
end
