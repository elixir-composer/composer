defmodule Composer.CbStd.Steps.Completions.Composer do
  @moduledoc """
  Install composer's shell completion script

  Copies composer's completion script for a shell, from this step's
  templates (`_composer/composer.{bash,zsh,fish}`), to where that shell
  loads it. The script completes addresses for
  composer's mix tasks from each project's `_build/composer/index`, without
  starting the BEAM, so one global copy serves every project.

      mix composer.step.run cb_std:completions:composer -- --shell zsh
      mix composer.step.run cb_std:completions:composer -- --shell fish --path ~/dotfiles/composer.fish

  `--shell` picks the script (bash by default) and its default path:

  - `bash`: `~/.complete/mix_composer.bash`, which the shell config sources
    at startup. It must be sourced after the mix_completions script, which
    the file name ensures (`mix_autocomplete.bash` sorts first). The step
    never creates `~/.complete`; the shell config owns it.
  - `zsh`: `~/.zsh/functions/_composer_mix`, which must be on `fpath` after
    mix_completions' `_mix`.
  - `fish`: `~/.config/fish/conf.d/composer_mix.fish`, which fish sources
    at startup (a `completions/mix.fish` would hide the one fish ships).

  `--path` writes it somewhere else; its directory is created as needed.

  Rerun it after upgrading composer. The file lives outside the project, so
  it is written directly and never shows in Igniter's diff.

  References:

  - [the completion guide](completion.md)
  - https://hex.pm/packages/mix_completions
  """

  use Composer.Step,
    summary: "Installs composer's shell completion script",
    action: :gen,
    capability: [:devtools],
    phase: :finalize,
    stability: :experimental,
    tags: [:completions]

  @targets %{
    # Sorts after mix_autocomplete.bash, so it is sourced last.
    "bash" => %{path: "~/.complete/mix_composer.bash", create_dir?: false},
    "zsh" => %{path: "~/.zsh/functions/_composer_mix", create_dir?: true},
    # Not completions/mix.fish, which would hide fish's own mix.fish.
    "fish" => %{path: "~/.config/fish/conf.d/composer_mix.fish", create_dir?: true}
  }

  @shells Map.keys(@targets)

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{schema: [shell: :string, path: :string], defaults: [shell: "bash"]}
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = igniter.args.options
    shell = options[:shell]

    if shell in @shells do
      path = options[:path] || @targets[shell].path
      install(igniter, shell, Path.expand(path), create_dir?: options[:path] != nil)
    else
      Igniter.add_issue(igniter, "unknown --shell #{inspect(shell)}; use bash, zsh or fish")
    end
  end

  @doc "The supported shells."
  @spec shells() :: [String.t()]
  def shells, do: @shells

  @doc """
  Returns each shell's install path, unexpanded (`~/...`), and whether its
  directory may be created.
  """
  def targets, do: @targets

  @doc "The completion script for `shell`, read from this step's templates."
  @spec script!(String.t()) :: binary()
  def script!(shell) when shell in @shells do
    template("composer.#{shell}") |> Composer.Templates.path() |> File.read!()
  end

  @doc """
  Writes `shell`'s script to `path`. Bash is not installed without its
  directory: `~/.complete` is set up, and sourced, by the shell config.
  `create_dir?: true` creates the directory for any shell.
  """
  def install(igniter, shell, path, opts \\ []) do
    script = script!(shell)
    dir = Path.dirname(path)
    create_dir? = Keyword.get(opts, :create_dir?, false) or @targets[shell].create_dir?

    cond do
      not create_dir? and not File.dir?(dir) ->
        Igniter.add_issue(igniter, "#{dir} does not exist; set up the shell config first")

      File.read(path) == {:ok, script} ->
        File.chmod!(path, 0o755)
        Igniter.add_notice(igniter, "#{path} is up to date")

      true ->
        File.mkdir_p!(dir)
        File.write!(path, script)
        File.chmod!(path, 0o755)
        Igniter.add_notice(igniter, "composer completions are installed in #{path}")
    end
  end
end
