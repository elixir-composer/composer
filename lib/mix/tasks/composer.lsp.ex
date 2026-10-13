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
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv), do: Composer.LSP.start([])
end
