defmodule Mix.Tasks.Composer.Completion do
  @shortdoc "Prints a shell completion script"

  @moduledoc """
  Prints a completion script for bash, zsh or fish.

      mix composer.completion bash > ~/.complete/mix_composer.bash
      mix composer.completion zsh > ~/.zsh/functions/_composer_mix
      mix composer.completion fish > ~/.config/fish/conf.d/composer_mix.fish

  The script completes step ids for `mix composer.step.{run,show,help,edit}`,
  recipe ids for `mix composer.recipe.{run,show,help,edit}`, and cookbook,
  chapter and group stems (`cb_lab/`, `cb_std:cluster:`) for
  `mix composer.recipe.list` and `mix composer.step.list`, from
  `_build/composer/index`, without starting the BEAM.

  It wraps [mix_completions](https://hex.pm/packages/mix_completions): every
  other `mix` completion, task names and `mix help` included, is handed to
  it when it is installed.

    * bash: source the script after mix_completions' script. A
      `~/.complete/*.bash` glob sorts `mix_composer.bash` after
      `mix_autocomplete.bash`.
    * zsh: put the script on `fpath` after mix_completions' `_mix`.
    * fish: the script adds to the task completions fish ships in its own
      `mix.fish`; mix_completions has no fish support. Save it in `conf.d/`:
      a user-level `completions/mix.fish` would hide fish's.

  Every composer task refreshes the index; when it is missing, or older than
  `mix.lock`, no ids are offered until `mix composer.index` runs. The script
  hints once per session when the index or mix_completions' task cache is
  stale. `Composer.Completion` gives the scripts and paths to installers.
  See the [completion guide](completion.md).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case argv do
      [] ->
        Composer.CLI.help("composer.completion")

      [shell] ->
        case Composer.Completion.script(shell) do
          {:ok, script} -> IO.write(script)
          {:error, :unknown_shell} -> usage()
        end

      _ ->
        usage()
    end
  end

  defp usage, do: Mix.raise("Usage: mix composer.completion bash|zsh|fish")
end
