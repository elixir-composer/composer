defmodule Mix.Tasks.Composer.Completion do
  @shortdoc "Prints a shell completion script"

  @moduledoc """
  Prints a completion script for bash, zsh or fish.

      mix composer.completion bash > ~/.local/share/bash-completion/completions/mix-composer
      mix composer.completion zsh > ~/.zsh/functions/_composer_mix
      mix composer.completion fish > ~/.config/fish/completions/mix.fish

  The script completes step ids for `mix composer.step.{run,help}`, recipe
  ids for `mix composer.recipe.{run,show,edit}`, and cookbook and group names
  (`local`, `local:ash/`) for `mix composer.recipe.list`, from
  `_build/composer/index`
  without starting the BEAM, and hands every other `mix` completion to
  [mix_completions](https://hex.pm/packages/mix_completions) when it is
  installed. In bash, source it after mix_completions' script.

  Every composer task refreshes the index; when it is missing, or older than
  `mix.lock`, no ids are offered until `mix composer.index` runs.
  """

  use Mix.Task

  @shells ~w(bash zsh fish)

  @impl Mix.Task
  def run(argv) do
    case argv do
      [shell] when shell in @shells ->
        :composer
        |> :code.priv_dir()
        |> Path.join("completion/composer.#{shell}")
        |> File.read!()
        |> IO.write()

      _ ->
        Mix.raise("Usage: mix composer.completion bash|zsh|fish")
    end
  end
end
