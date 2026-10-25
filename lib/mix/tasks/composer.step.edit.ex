defmodule Mix.Tasks.Composer.Step.Edit do
  @shortdoc "Opens a step's source file in your editor"

  @moduledoc """
  Opens the source file of a step in your editor, at its
  `use Composer.Step` line.

      $ mix composer.step.edit cb_std:setup:credo

  The editor command comes from `COMPOSER_EDITOR`, then `VISUAL`, then
  `EDITOR`; `__FILE__` and `__LINE__` in it are replaced with the file and
  line (see `Composer.Editor`):

      # Neovim in the current terminal
      export COMPOSER_EDITOR="nvim +__LINE__ __FILE__"

      # Neovim in a new Ghostty window
      export COMPOSER_EDITOR="ghostty -e 'nvim +__LINE__ __FILE__'"

  The step is found as `mix composer.step.run` finds it. A step from a
  dependency's cookbook (including the built-in `cb_std` steps) opens too,
  with a warning: edits under `deps/` are lost when the dependency is
  updated. A `hex:` package has no step file, so it cannot be edited.

  ## Options

    * `--print` - print `path:line` instead of opening an editor
  """

  use Mix.Task

  alias Composer.{CLI, Editor, Resolver}
  alias Composer.Lint.Locate

  @impl Mix.Task
  def run(argv) do
    {opts, args} = CLI.parse!(argv, print: :boolean)

    ref =
      case args do
        [ref] -> ref
        _ -> Mix.raise("Usage: mix composer.step.edit STEP")
      end

    cookbooks = CLI.cookbooks!()

    meta =
      case CLI.ok!(Resolver.find_step(cookbooks, ref, CLI.context(cookbooks))) do
        {:step, meta} -> meta
        {:hex, package} -> Mix.raise("#{ref} is the Hex package #{package}, not a step")
      end

    path =
      Locate.source(meta.module) ||
        Mix.raise("The source file of #{meta.ref} (#{inspect(meta.module)}) was not found")

    line = line(path)

    if opts[:print] do
      Mix.shell().info("#{path}:#{line}")
    else
      Editor.warn_if_dep(path)
      Editor.open!(path, line)
    end
  end

  # The line of `use Composer.Step`; 1 when the file cannot be parsed.
  defp line(path) do
    case Locate.step_use(path) do
      {{line, _column}, _end} -> line
      nil -> 1
    end
  end
end
