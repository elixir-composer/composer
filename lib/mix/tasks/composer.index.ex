defmodule Mix.Tasks.Composer.Index do
  @shortdoc "Rebuilds the shell completion index"

  @moduledoc """
  Rebuilds `_build/composer/index`, the file the completion script reads.

      mix composer.index

  Every composer task refreshes the index as a side effect, so this is only
  needed after adding a dependency or a recipe. See `Composer.Index`,
  `Composer.Completion` and the [completion guide](completion.md).

  ## Options

  """

  use Mix.Task

  alias Composer.CLI

  @impl Mix.Task
  def run(argv) do
    CLI.require_project!()
    {_opts, _args} = CLI.parse!(argv)
    cookbooks = CLI.cookbooks!()
    path = Composer.Index.path()
    Composer.Index.write(cookbooks, path)
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end
end
