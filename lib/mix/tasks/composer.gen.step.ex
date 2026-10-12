defmodule Mix.Tasks.Composer.Gen.Step do
  @shortdoc "Scaffolds a step and its test"

  @moduledoc """
  Scaffolds a step in the current project's cookbook, with every facet
  stubbed out, and a test for it.

      mix composer.gen.step tailwind_plugins
      mix composer.gen.step ash/postgres

  writes `lib/composer/<app>/steps/ash/postgres.ex` (module
  `Composer.<App>.Steps.Ash.Postgres`) and
  `test/composer/<app>/steps/ash/postgres_test.exs`.

  A step's templates go in the directory named after its file with a
  leading underscore (`lib/composer/<app>/steps/ash/_postgres/`), and `template/1` refers to
  them by a path relative to it. The directory is not created; add it when
  the step needs a template.

  Group related steps with `/`: `ash/postgres` and `ash/sqlite` read better,
  and list together, than `ash_postgres` and `ash_sqlite`. Use a flat name
  for a step that stands alone.

  If the cookbook module is guarded for bundling (see
  `mix composer.gen.cookbook --bundled`), the step and its test get the same
  guard.
  """

  use Igniter.Mix.Task

  alias Mix.Tasks.Composer.Gen.Cookbook, as: GenCookbook

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      positional: [:path],
      example: "mix composer.gen.step ash/postgres"
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    path = normalize!(igniter.args.positional.path)
    app = Igniter.Project.Application.app_name(igniter)
    name = GenCookbook.cookbook_name(app)
    module = Composer.Step.module_for(name, path)
    cookbook_file = "lib/composer/#{name}.ex"
    bundled? = bundled?(igniter, cookbook_file)

    igniter
    |> Igniter.create_new_file(
      "lib/composer/#{name}/steps/#{path}.ex",
      module |> step_source(path) |> GenCookbook.guard(bundled?)
    )
    |> Igniter.create_new_file(
      "test/composer/#{name}/steps/#{path}_test.exs",
      module |> test_source() |> GenCookbook.guard(bundled?)
    )
    |> then(fn igniter ->
      if Igniter.exists?(igniter, cookbook_file) do
        igniter
      else
        Igniter.add_warning(igniter, """
        #{cookbook_file} does not exist, so the step belongs to no cookbook yet. \
        Create it with: mix composer.gen.cookbook
        """)
      end
    end)
    |> Igniter.add_notice(
      "Run `mix composer.cookbook.manifest` after filling in the step's summary and facets."
    )
  end

  defp normalize!(path) do
    case Composer.Ref.parse(path) do
      {:ok, %Composer.Ref{cookbook: nil, path: path}} ->
        path

      _ ->
        Mix.raise("""
        Invalid step path #{inspect(path)}. A step path is one or more \
        `/`-separated lowercase [a-z0-9_] segments, e.g. ash/postgres.
        """)
    end
  end

  defp bundled?(igniter, cookbook_file) do
    if Igniter.exists?(igniter, cookbook_file) do
      igniter = Igniter.include_existing_file(igniter, cookbook_file)

      igniter.rewrite
      |> Rewrite.source!(cookbook_file)
      |> Rewrite.Source.get(:content)
      |> String.contains?("Code.ensure_loaded?(Composer)")
    else
      false
    end
  end

  defp step_source(module, path) do
    """
    defmodule #{inspect(module)} do
      use Composer.Step,
        summary: "TODO: describe what #{path} does, in one line",
        # :add, :remove, :gen, :config or :patch
        action: :add,
        # e.g. :phoenix, :liveview, :ash, :ecto
        frameworks: [],
        # e.g. :auth, :jobs, :deploy, :css, :testing, :devtools, :database
        capability: [],
        # :cleanup, :setup, :generate or :finalize (advisory)
        phase: :setup,
        # :experimental, :beta, :stable or :deprecated
        stability: :experimental,
        tags: [],
        # step refs ("core:setup/credo"), {:executable, "bun"}, {:package, :phoenix, "~> 1.8"}
        requires: [],
        provides: [],
        conflicts: []

      @impl Igniter.Mix.Task
      def igniter(igniter) do
        # Change the project here, for example:
        #
        #     Igniter.Project.Deps.add_dep(igniter, {:some_package, "~> 1.0"})
        #
        # Templates go beside this file, in steps/#{Composer.Step.template_dir(path)}/, and template/1
        # takes a path relative to that directory:
        #
        #     Composer.Templates.copy_file(igniter, template("file.txt.eex"), "file.txt")
        #
        # See https://hexdocs.pm/igniter and Composer.Templates.
        igniter
      end
    end
    """
  end

  defp test_source(module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      import Igniter.Test

      test "applies to a fresh project" do
        test_project()
        |> Igniter.compose_task(#{inspect(module)})
        |> assert_unchanged()
      end
    end
    """
  end
end
