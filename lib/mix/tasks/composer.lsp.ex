defmodule Mix.Tasks.Composer.Lsp do
  @shortdoc "Starts the composer-ls language server (stdio)"

  @moduledoc """
  Starts `composer-ls`, the language server for recipe group files, on
  stdio. Your editor runs it; see the Composer LSP guide.

      mix composer.lsp

  The host project is the directory the editor starts the server in:
  start your editor from the project (`cd my_app && nvim`). The server
  names the project in a message at startup and at the foot of every
  hover.

  The server needs the `gen_lsp` package, an optional dependency of
  composer. Add it to the host project's deps:

      {:gen_lsp, "~> 0.11.4", only: :dev}

  Without it, this task says so and exits.
  """

  use Mix.Task

  alias Composer.Error

  @impl Mix.Task
  def run(argv), do: run(argv, Composer.LSP.available?())

  @doc false
  # `available?` is injected by tests.
  def run(_argv, true), do: Composer.LSP.start([])

  def run(_argv, false) do
    Mix.shell().error(Error.message(:gen_lsp_missing))
    exit({:shutdown, 1})
  end
end
