defmodule Mix.Tasks.Composer.Cookbook.Lint do
  @shortdoc "Checks this project's cookbook, or your local recipes"

  @moduledoc """
  Checks the current project's cookbook (in composer itself, `core`):

    * every step has a summary, an `action` and a `stability`
    * every step has a test at `test/composer/<cookbook>/steps/<id>_test.exs`
    * every step reference in `requires` resolves
    * `lib/composer/<cookbook>/manifest.exs` is up to date
    * every recipe group is well formed (see `Composer.Lint`)
    * every reference in every recipe resolves, and every recipe resolves
      as a whole

  With `--local`, checks your local recipes instead: the config directory
  holds only `recipes/`, every group is well formed and every recipe
  resolves against the project's cookbooks.

  With `--file`, checks one recipe group file, local or a cookbook's (found
  from its path), and reports only the problems in that file, plus one at
  each `{:use, ...}` of a recipe that has problems of its own. This is
  what an editor runs on save; see the lint guide.

  Exits non-zero when there is an error, in every format, so it can run in
  CI.

      mix composer.cookbook.lint
      mix composer.cookbook.lint --local
      mix composer.cookbook.lint --format compact --file ~/.config/composer/recipes/ash.exs
      mix composer.cookbook.lint --format github

  ## Formats

    * `text` (default) - each problem after its `path:line:col:` location,
      warnings first; errors make the task fail with the list
    * `compact` - one line per problem,
      `file:line:col: severity: message [code]`, for editors
    * `json` - an array of diagnostics
    * `github` - GitHub Actions annotations

  In every format but `text`, stdout holds nothing but the diagnostics
  (compiling runs quietly), and errors end the task with exit status 1.
  Dependencies that need compiling are compiled by Mix before this task
  starts; set `MIX_QUIET=1` to silence that too.

  ## Options

    * `--local` - lint your local recipes instead of the project's cookbook
    * `--file PATH` - lint one recipe group file
    * `--format FORMAT` - `text`, `compact`, `json` or `github`
    * `-c`, `--config` - the local config directory (see `Composer.Local`)
  """

  use Mix.Task

  alias Composer.{CLI, Discovery, Lint, Local, Manifest}
  alias Composer.Lint.{Diagnostic, Format}

  @formats ~w(text compact json github)

  @impl Mix.Task
  def run(argv) do
    CLI.require_project!()
    {opts, _args} = CLI.parse!(argv, local: :boolean, format: :string, file: :string)
    format = format!(opts[:format])

    result =
      CLI.quietly(format != :text, fn ->
        cond do
          opts[:file] -> lint_file(opts[:file], opts)
          opts[:local] -> lint_local(opts[:config])
          true -> lint_cookbook(opts[:config])
        end
      end)

    report(format, result)
  end

  defp format!(nil), do: :text
  defp format!(format) when format in @formats, do: String.to_atom(format)

  defp format!(format),
    do: Mix.raise("Unknown --format #{format}. The formats are: #{Enum.join(@formats, ", ")}.")

  defp lint_cookbook(config) do
    cookbooks = CLI.cookbooks!(config)

    cookbook =
      Discovery.own(cookbooks) ||
        Mix.raise("""
        This project has no cookbook to lint. Create one with:

            mix composer.gen.cookbook

        or lint your local recipes with: mix composer.cookbook.lint --local
        """)

    %{
      diagnostics: Lint.run(cookbook, cookbooks, root()).diagnostics,
      valid: "Cookbook #{cookbook.name} is valid.",
      problems: "Cookbook #{cookbook.name} has",
      fallback: Manifest.path(cookbook)
    }
  end

  # Local is linted from the directory itself, so a steps/ directory (which
  # stops local from loading) is reported rather than raised.
  defp lint_local(config) do
    dir = local_dir!(config)

    %{
      diagnostics: Lint.local(dir, cookbooks()).diagnostics,
      valid: "Local recipes in #{dir} are valid.",
      problems: "Local recipes in #{dir} have",
      fallback: local_fallback(dir)
    }
  end

  defp lint_file(file, opts) do
    path = Path.expand(file)
    dir = local_dir!(opts[:config], false)
    cookbooks = cookbooks()
    cookbook = CLI.ok!(Lint.owner(cookbooks, path, local: dir))

    if opts[:local] && cookbook.kind != :local do
      Mix.raise(Composer.Error.message({:lint_file_mismatch, path, cookbook.name}))
    end

    shown = Path.relative_to_cwd(path)

    %{
      diagnostics: Map.fetch!(Lint.files(cookbooks, [path], local: dir, root: root()), path),
      valid: "#{shown} is valid.",
      problems: "#{shown} has",
      fallback: path
    }
  end

  defp local_dir!(config, check? \\ true) do
    {dir, how} = Local.dir(config)

    if check? and how == :explicit and not File.dir?(dir) do
      Mix.raise(Composer.Error.message({:config_dir_missing, dir}))
    end

    dir
  end

  # Without local, which lint builds from the directory itself.
  defp cookbooks do
    Mix.Task.run("compile", [])
    discovery = Application.get_env(:composer, :discovery, [])
    CLI.ok!(Discovery.cookbooks(Keyword.merge(discovery, local: false)))
  end

  defp root, do: Path.dirname(Mix.Project.project_file())

  # Where compact output puts a local problem that has no location: the
  # first group file, else the config directory.
  defp local_fallback(dir) do
    case dir |> Path.join("recipes/*.exs") |> Path.wildcard() |> Enum.sort() do
      [first | _] -> first
      [] -> dir
    end
  end

  defp report(:text, %{diagnostics: diagnostics} = result) do
    %{errors: errors, warnings: warnings} = Format.text(diagnostics)
    Enum.each(warnings, &Mix.shell().info([:yellow, "warning: ", &1, :reset]))

    case errors do
      [] ->
        Mix.shell().info(result.valid)

      errors ->
        Mix.raise(
          "#{result.problems} #{length(errors)} problem(s):\n\n" <>
            Enum.map_join(errors, "\n", &("  * " <> &1))
        )
    end
  end

  defp report(format, %{diagnostics: diagnostics, fallback: fallback}) do
    payload =
      case format do
        :compact -> Format.compact(diagnostics, fallback)
        :json -> Format.json(diagnostics)
        :github -> Format.github(diagnostics, fallback)
      end

    # Straight to stdout, not through the Mix shell: with MIX_QUIET=1 (which
    # also silences compiling the dependencies, before this task can start)
    # the shell prints nothing.
    if payload != "", do: IO.puts(payload)
    if Enum.any?(diagnostics, &Diagnostic.error?/1), do: exit({:shutdown, 1})
  end
end
