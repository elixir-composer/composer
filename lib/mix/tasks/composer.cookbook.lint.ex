defmodule Mix.Tasks.Composer.Cookbook.Lint do
  @shortdoc "Checks this project's cookbook"

  @moduledoc """
  Checks the current project's cookbook (in composer itself, `cb_std`):

    * every step has a summary, an `action` and a `stability`
    * every step has a test at `test/composer/<cookbook>/steps/<id>_test.exs`
    * every step reference in `requires` resolves
    * `lib/composer/<cookbook>/manifest.exs` is up to date
    * every recipe group is well formed (see `Composer.Lint`)
    * every reference in every recipe resolves, and every recipe resolves
      as a whole

  With `--file`, checks one recipe group file of any installed cookbook
  (found from its path), and reports only the problems in that file, plus one at
  each `{:use, ...}` of a recipe that has problems of its own. This is
  what an editor runs on save; see the lint guide.

  Exits non-zero when there is an error, in every format, so it can run in
  CI.

      mix composer.cookbook.lint
      mix composer.cookbook.lint --format compact --file lib/composer/my_app/recipes/ash.exs
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

    * `--file PATH` - lint one recipe group file
    * `--format FORMAT` - `text`, `compact`, `json` or `github`
  """

  use Mix.Task

  alias Composer.{CLI, Discovery, Lint, Manifest}
  alias Composer.Lint.{Diagnostic, Format}

  @formats ~w(text compact json github)

  @impl Mix.Task
  def run(argv) do
    CLI.require_project!()
    {opts, _args} = CLI.parse!(argv, format: :string, file: :string)
    format = format!(opts[:format])
    cookbooks = CLI.cookbooks!(quiet: format != :text)

    result =
      if opts[:file],
        do: lint_file(opts[:file], cookbooks),
        else: lint_cookbook(cookbooks)

    report(format, result)
  end

  defp format!(nil), do: :text
  defp format!(format) when format in @formats, do: String.to_atom(format)

  defp format!(format),
    do: Mix.raise("Unknown --format #{format}. The formats are: #{Enum.join(@formats, ", ")}.")

  defp lint_cookbook(cookbooks) do
    cookbook =
      Discovery.own(cookbooks) ||
        Mix.raise("""
        This project has no cookbook to lint. Create one with:

            mix composer.gen.cookbook
        """)

    %{
      diagnostics:
        Lint.run(cookbook, cookbooks, root(), project: Mix.Project.config()).diagnostics,
      valid: "Cookbook #{cookbook.name} is valid.",
      problems: "Cookbook #{cookbook.name} has",
      fallback: Manifest.path(cookbook)
    }
  end

  defp lint_file(file, cookbooks) do
    path = Path.expand(file)
    CLI.ok!(Lint.owner(cookbooks, path))
    shown = Path.relative_to_cwd(path)

    %{
      diagnostics: Map.fetch!(Lint.files(cookbooks, [path], root: root()), path),
      valid: "#{shown} is valid.",
      problems: "#{shown} has",
      fallback: path
    }
  end

  defp root, do: Path.dirname(Mix.Project.project_file())

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
