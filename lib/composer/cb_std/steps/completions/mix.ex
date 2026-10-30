defmodule Composer.CbStd.Steps.Completions.Mix do
  @moduledoc """
  Generate mix completions

  Runs `mix complete`, which writes the project's task names and shortdocs to
  `.mix_complete.cache`, and writes the generic completion function that
  `mix complete.bash` prints to `~/.complete/mix_autocomplete.bash`, which the
  shell config sources at startup and which reads the cache on each Tab.

  The cache goes stale when tasks change, so rerun the step after deps
  change or a composer upgrade, or when composer's completion script hints
  "mix task completions are stale; run mix complete" (running `mix complete`
  alone is enough).

  ## Completing after `mix help`

  mix_completions completes task names after `mix help` since 0.4.1 (upstream
  PR erikareads/mix_completions#2); 0.3.0 completed them only right after
  `mix`. The change is in the shell function, not the cache, so an installed
  archive whose `mix complete.bash` output does not complete after `help` is
  replaced by the Hex release and `~/.complete/mix_autocomplete.bash` is
  rewritten.

  The completion script lives outside the project, so it is written directly
  and never shows in Igniter's diff.

  References:

  - https://erikarow.land/articles/mix-completions
  - https://hex.pm/packages/mix_completions
  - https://github.com/erikareads/mix_completions
  - https://github.com/erikareads/mix_completions/pull/2
  """

  use Composer.Step,
    summary: "Caches mix task names and installs bash completion for mix",
    action: :gen,
    capability: [:devtools],
    phase: :finalize,
    stability: :experimental,
    tags: [:completions]

  @archive_source ~w(hex mix_completions)
  @complete_dir "~/.complete"
  @script_file "mix_autocomplete.bash"
  @help_case "[[ $prev == 'help' ]]"
  @cache_file ".mix_complete.cache"
  @legacy_script ".mix_completions.bash"

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    case ensure_archive_installed() do
      {:ok, script} ->
        igniter
        |> generate_cache()
        |> write_script(script)
        |> ignore_cache()
        |> remove_legacy_script()

      {:error, issue} ->
        Igniter.add_issue(igniter, issue)
    end
  end

  # Asks the installed archive for its bash script rather than looking for it
  # with `Mix.Task.get("complete")`: inside a project, compilation prunes
  # archive ebins from the code path, so the task never resolves in-process.
  defp ensure_archive_installed do
    with {:error, _} <- help_aware_script(),
         :ok <- install_archive() do
      help_aware_script()
    end
  end

  # Runs outside the project, so no compile output reaches stdout (the cache
  # `mix complete.bash` also writes goes to ~/.cache instead).
  defp help_aware_script do
    case System.cmd("mix", ["complete.bash"], cd: System.tmp_dir!()) do
      {script, 0} ->
        if String.contains?(script, @help_case),
          do: {:ok, script},
          else: {:error, "the installed mix_completions does not complete after `mix help`"}

      {_output, status} ->
        {:error, "`mix complete.bash` failed (exit #{status})"}
    end
  end

  # Installs synchronously in a separate mix process, so the archive is
  # available to the `mix complete` calls that follow.
  defp install_archive do
    args = ["archive.install" | @archive_source]
    command = Enum.join(["mix" | args], " ")
    Mix.shell().info("Installing the mix_completions archive (#{command})...")

    case System.cmd("mix", args ++ ["--force"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "`#{command}` failed (exit #{status}):\n#{output}"}
    end
  end

  # `mix complete` writes the cache itself (into the project directory, since
  # mix.exs exists there) rather than printing it.
  defp generate_cache(igniter) do
    case System.cmd("mix", ["complete"], stderr_to_stdout: true) do
      {_output, 0} ->
        Igniter.add_notice(igniter, "mix task completions are cached in #{@cache_file}")

      {output, status} ->
        Igniter.add_issue(igniter, "`mix complete` failed (exit #{status}):\n#{output}")
    end
  end

  defp write_script(igniter, script) do
    dir = Path.expand(@complete_dir)
    path = Path.join(dir, @script_file)

    cond do
      not File.dir?(dir) ->
        Igniter.add_warning(
          igniter,
          "#{@complete_dir} does not exist; mix's completion function was not installed"
        )

      File.read(path) == {:ok, script} ->
        File.chmod!(path, 0o755)
        igniter

      true ->
        File.write!(path, script)
        File.chmod!(path, 0o755)
        Igniter.add_notice(igniter, "mix completions are installed in #{path}")
    end
  end

  defp ignore_cache(igniter) do
    Composer.Edit.Project.gitignore(igniter, @cache_file,
      comment: "mix task completion cache (mix complete)"
    )
  end

  # Earlier versions of this step wrote the generic bash script per project.
  defp remove_legacy_script(igniter) do
    if Igniter.exists?(igniter, @legacy_script) do
      Igniter.rm(igniter, @legacy_script)
    else
      igniter
    end
  end
end
