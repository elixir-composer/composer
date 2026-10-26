defmodule Composer.Completion do
  @moduledoc """
  Composer's shell completion scripts, for `mix composer.completion` and for
  installers in other packages.

  Each script completes step and recipe addresses for composer's tasks from
  `_build/composer/index` (see `Composer.Index`), without starting the BEAM:

    * **bash** wraps mix_completions: it registers its own `complete -F` for
      `mix` and hands every other word to `_mix_complete_complete`, so it
      must be sourced after mix_completions' script.
    * **zsh** is a `#compdef mix` function, `_composer_mix`, that calls
      mix_completions' `_mix` for every other word, so it goes on `fpath`
      after `_mix`.
    * **fish** adds address completions to `mix`; fish completions add up,
      so nothing else is replaced. It goes in `conf.d/`, not as a
      `completions/mix.fish`, which would hide the `mix.fish` fish ships.

  The scripts also hint, once per shell session, when the index or
  mix_completions' task cache is stale. See the
  [completion guide](completion.md).
  """

  @shells ~w(bash zsh fish)

  @paths %{
    # Sorts after mix_autocomplete.bash, so it is sourced last.
    "bash" => "~/.complete/mix_composer.bash",
    "zsh" => "~/.zsh/functions/_composer_mix",
    # Not completions/mix.fish, which would hide fish's own mix.fish.
    "fish" => "~/.config/fish/conf.d/composer_mix.fish"
  }

  @doc "The supported shells."
  @spec shells() :: [String.t()]
  def shells, do: @shells

  @doc "The completion script for `shell`."
  @spec script(String.t()) :: {:ok, binary()} | {:error, :unknown_shell}
  def script(shell) when shell in @shells do
    {:ok, File.read!(Path.join(:code.priv_dir(:composer), "completion/composer.#{shell}"))}
  end

  def script(_shell), do: {:error, :unknown_shell}

  @doc "Like `script/1`, but raises on an unknown shell."
  @spec script!(String.t()) :: binary()
  def script!(shell) do
    case script(shell) do
      {:ok, script} -> script
      {:error, :unknown_shell} -> raise ArgumentError, "unknown shell: #{inspect(shell)}"
    end
  end

  @doc """
  Where `shell`'s script is installed by default, unexpanded (`~/...`).

      iex> Composer.Completion.default_path("bash")
      "~/.complete/mix_composer.bash"
  """
  @spec default_path(String.t()) :: String.t()
  def default_path(shell) when shell in @shells, do: Map.fetch!(@paths, shell)
end
