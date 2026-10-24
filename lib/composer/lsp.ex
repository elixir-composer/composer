defmodule Composer.LSP do
  @moduledoc """
  `composer-ls`, the language server for chapter files, started by
  `mix composer.lsp`. See the Composer LSP guide.

  The server runs beside the Elixir language server and handles recipe
  references only: diagnostics on open and save (in the saved file and the
  files that include it), hover, goto-definition, document links for
  `hex:` refs, completion and quick fixes. It is a thin adapter over
  `Composer.Lint`, `Composer.Recipe.Locator` and `Composer.Resolver`.

  The host project is the working directory the editor starts the server
  in. Only `Composer.LSP.Server` uses GenLSP.

  ## Startup

  Before anything owns stdio, the project is compiled and its cookbooks
  discovered with a quiet Mix shell. Then the Mix shell stays quiet,
  Logger writes to stderr, and the server is started with stdout reserved
  for protocol messages (`Composer.LSP.Server.run/1`). The call blocks.
  """

  alias Composer.{CLI, Discovery}

  @doc "Starts the language server on stdio and blocks."
  @spec start(keyword()) :: no_return()
  def start(_opts \\ []) do
    CLI.require_project!()

    cookbooks =
      CLI.quietly(fn ->
        Mix.Task.run("compile", [])
        CLI.ok!(discover())
      end)

    Mix.shell(Mix.Shell.Quiet)
    log_to_stderr()

    Composer.LSP.Server.run(server_opts(cookbooks))
  end

  @doc false
  # The workspace options of a server for the current project.
  def server_opts(cookbooks) do
    root = Path.dirname(Mix.Project.project_file())

    [
      cookbooks: cookbooks,
      entries: entries(cookbooks),
      root: root,
      project: to_string(Mix.Project.config()[:app])
    ]
  end

  @doc "The completion entries of `cookbooks`."
  @spec entries([Composer.Cookbook.t()]) :: [{String.t(), String.t(), String.t() | nil}]
  def entries(cookbooks), do: Enum.flat_map(cookbooks, &Composer.Index.entries/1)

  @doc "The cookbooks of the current project."
  @spec discover() :: {:ok, [Composer.Cookbook.t()]} | {:error, term()}
  def discover do
    discovery = Application.get_env(:composer, :discovery, [])
    Discovery.cookbooks(discovery)
  end

  @doc """
  Recompiles the project, as `IEx.Helpers.recompile/0` does, and
  rediscovers its cookbooks. Returns `{:error, message}` on failure.
  """
  @spec reload_cookbooks() :: {:ok, [Composer.Cookbook.t()]} | {:error, String.t()}
  def reload_cookbooks do
    CLI.quietly(fn ->
      Mix.Task.reenable("compile")
      Mix.Task.reenable("compile.all")
      compilers = Mix.Project.config()[:compilers] || Mix.compilers()
      Enum.each(compilers, &Mix.Task.reenable("compile.#{&1}"))

      case Mix.Task.run("compile", []) do
        {:error, diagnostics} ->
          {:error, "compilation failed with #{length(List.wrap(diagnostics))} error(s)"}

        _ ->
          case discover() do
            {:ok, cookbooks} -> {:ok, cookbooks}
            {:error, reason} -> {:error, Composer.Error.message(reason)}
          end
      end
    end)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # A handler's type can't be changed in place, so the default handler is
  # replaced by one writing to stderr. GenLSP logs every message at debug
  # level, and editors log a server's stderr, so debug is left out.
  defp log_to_stderr do
    _ = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, :logger_std_h, %{
        config: %{type: :standard_error},
        formatter: Logger.default_formatter()
      })

    Logger.configure(level: :info)
  end
end
