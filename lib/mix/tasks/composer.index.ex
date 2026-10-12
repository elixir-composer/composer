defmodule Mix.Tasks.Composer.Index do
  @shortdoc "Rebuilds the shell completion index"

  @moduledoc """
  Rebuilds `_build/composer/index`, the file the completion script reads.

      mix composer.index

  Every composer task refreshes the index as a side effect, so this is only
  needed after adding a dependency or a local recipe. See `Composer.Index`
  and `mix composer.completion`.

  ## Options

    * `-c`, `--config` - the local config directory (see `Composer.Local`)
  """

  use Mix.Task

  alias Composer.CLI

  @impl Mix.Task
  def run(argv) do
    CLI.require_project!()
    {opts, _args} = CLI.parse!(argv)
    cookbooks = CLI.cookbooks!(opts[:config])
    path = Composer.Index.path()
    Composer.Index.write(cookbooks, path)
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end
end
