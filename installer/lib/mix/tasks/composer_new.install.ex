defmodule Mix.Tasks.ComposerNew.Install do
  @shortdoc "Installs packages with Igniter, keeping version requirements (used by composer.new)"

  @moduledoc """
  `mix igniter.install`, as `mix composer.new` runs it inside the new app:

      mix composer_new.install PKG[@SOURCE][,PKG...] [IGNITER.INSTALL OPTIONS]

      mix composer_new.install 'composer@~> 0.3,cb_lab@github:elixir-composer/cb_lab' --only dev,test --yes

  SOURCE is written as in a `mix composer.new` REF: a version (`0.3.1`,
  `0.3`) or a version requirement (`~> 0.3`, `>= 1.0.0`), `github:`,
  `git:` or `path:`; with no SOURCE, the latest Hex release. Unlike
  `mix igniter.install`, a requirement is written to `mix.exs` as given
  (see `ComposerNew.Dep`). Every other argument goes to Igniter as
  `igniter.install` passes it on, and from there to each package's
  installer.

  The current project must depend on igniter, as an app made by
  `igniter.new` does.
  """

  use Mix.Task

  alias ComposerNew.Dep

  # Igniter is the app's dep, not the archive's: it is loaded at runtime.
  @compile {:no_warn_undefined, [Igniter.Util.Install, Igniter.Project.Deps]}

  @impl Mix.Task
  def run(argv) do
    {packages, argv} = Enum.split_while(argv, &(not String.starts_with?(&1, "-")))

    deps =
      packages
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&parse!/1)

    if deps == [],
      do: Mix.raise("Usage: mix composer_new.install PKG[@SOURCE][,PKG...] [OPTIONS]")

    # As igniter.install, before it reads its packages.
    Mix.Task.run("deps.compile")
    Mix.Task.run("deps.loadpaths")
    Mix.Task.run("compile", ["--no-compile"])

    if not Code.ensure_loaded?(Igniter.Util.Install) do
      Mix.raise("mix composer_new.install needs igniter as a dependency of the current project")
    end

    Application.ensure_all_started(:rewrite)

    deps
    |> Enum.map(fn {string, dep} ->
      case Dep.to_igniter(dep) do
        :latest -> Igniter.Project.Deps.determine_dep_type_and_version!(string, argv: argv)
        tuple -> tuple
      end
    end)
    |> Igniter.Util.Install.install(argv)
  end

  defp parse!(string) do
    case Dep.parse(string) do
      {:ok, dep} -> {string, dep}
      {:error, message} -> Mix.raise(message)
    end
  end
end
