defmodule Mix.Tasks.Composer.Cookbook.Manifest do
  @shortdoc "Writes this project's cookbook manifest"

  @moduledoc """
  Writes `lib/composer/<cookbook>/manifest.exs` for the current project's
  cookbook (in composer itself, `core`).

      mix composer.cookbook.manifest

  The manifest is plain data - ids, summaries and facets - that tools such
  as shell completion read without running cookbook code. Commit it;
  `mix composer.cookbook.lint` fails when it is out of date. See
  `Composer.Manifest`.
  """

  use Mix.Task

  alias Composer.{CLI, Discovery, Manifest}

  @impl Mix.Task
  def run(argv) do
    CLI.require_project!()
    {_opts, _args} = CLI.parse!(argv)
    cookbooks = CLI.cookbooks!()

    cookbook =
      Discovery.own(cookbooks) ||
        Mix.raise("""
        This project has no cookbook. Create one with:

            mix composer.gen.cookbook
        """)

    path = Manifest.path(cookbook)
    File.write!(path, cookbook |> Manifest.build() |> Manifest.render())
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end
end
