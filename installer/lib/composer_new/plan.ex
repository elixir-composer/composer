defmodule ComposerNew.Plan do
  @moduledoc """
  Turns `mix composer.new` argv into the list of commands to run.

  `build/2` is pure: everything it needs from the outside (the working
  directory, the home directory, the archive's version) comes in `env`,
  so `--dry-run` prints exactly what a run executes, and the tests check
  the same lists. The commands, in order (`[...]` is optional):

      rm -rf APP                                              (--reset)
      mix igniter.new APP --no-git --yes [--local REL] [--with TASK]
          [--with-args=ARGS] [--install PKG,...]
      (in APP) mix igniter.install composer@SRC[,COOKBOOK[@SRC]][,EXTRA,...]
          --only dev,test --yes
      (in APP) git init
      (in APP) git add -A
      (in APP) git commit -m "mix composer.new <argv as typed>"
      (in APP) mix composer.recipe.run COOKBOOK:GROUP/RECIPE [FLAGS]
                                               (REF given, no --no-recipe)

  `igniter.new` gets `--no-git`, so the history starts with the commit
  above rather than with igniter's own. `git init` is harmless in a repo
  the base generator already made, so it is always planned.

  `path:` sources are made absolute, since the install runs inside APP.
  The commit message keeps the argv as typed.
  """

  alias ComposerNew.{Argv, Command, Ref}

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
         :ok <- check_app(parsed.app) do
      {:ok, plan(argv, parsed, ref, composer, env)}
    end
  end

  defp parse_ref(nil), do: {:ok, nil}
  defp parse_ref(string), do: Ref.parse(string)

  defp composer_spec(nil, env), do: {:ok, "composer@~> #{env.version}"}

  defp composer_spec(spec, env) do
    case Ref.parse_source(spec) do
      {:ok, _source} -> {:ok, Ref.install_spec("composer", spec, env)}
      {:error, message} -> {:error, "--composer: " <> message}
    end
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

  defp plan(argv, parsed, ref, composer, env) do
    opts = parsed.opts

    app_arg =
      if String.starts_with?(parsed.app, "~"), do: Ref.expand(parsed.app, env), else: parsed.app

    dir = Ref.expand(app_arg, env)
    install = Enum.map(opts[:install], &Ref.expand_package(&1, env))
    cookbook = cookbook_spec(ref, env)

    deps =
      [composer | List.wrap(cookbook)] ++ Enum.map(opts[:extra_dep], &Ref.expand_package(&1, env))

    recipe = if ref && not opts[:no_recipe], do: "#{ref.cookbook}:#{ref.path}"

    create =
      ["igniter.new", app_arg, "--no-git", "--yes"] ++
        local(opts[:igniter_local], dir, env) ++
        if(opts[:with], do: ["--with", opts[:with]], else: []) ++
        if(opts[:with_args], do: ["--with-args=" <> opts[:with_args]], else: []) ++
        if(install != [], do: ["--install", Enum.join(install, ",")], else: [])

    commands =
      if(opts[:reset], do: [{:rm_rf, dir}], else: []) ++
        [
          %Command{label: :create, cmd: "mix", args: create},
          %Command{
            label: :install,
            cmd: "mix",
            args: ["igniter.install", Enum.join(deps, ","), "--only", "dev,test", "--yes"],
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

  # A core: recipe needs no cookbook install: core ships with composer.
  defp cookbook_spec(nil, _env), do: nil
  defp cookbook_spec(%{cookbook: "core"}, _env), do: nil
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
  defp source(%{cookbook: "core"}), do: "ships with composer"
  defp source(%{spec: nil}), do: "hex, latest"
  defp source(%{spec: spec}), do: spec

  defp base(opts) do
    with_args = if opts[:with_args], do: " " <> opts[:with_args], else: ""
    (opts[:with] || "new") <> with_args
  end
end
