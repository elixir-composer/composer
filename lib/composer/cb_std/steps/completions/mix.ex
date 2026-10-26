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

  ## Why a fork

  The mix_completions release on Hex (0.3.0) completes task names only right
  after `mix`, so `mix help comp<Tab>` offers nothing. toupeira's fork
  (branch `feat/help-completion`) also completes them after `mix help`; it is
  upstream PR erikareads/mix_completions#2, which has not been merged. The
  change is in the shell function, not the cache, so the step installs the
  archive from the fork and rewrites `~/.complete/mix_autocomplete.bash`. An
  installed archive whose `mix complete.bash` output does not complete after
  `help` (the Hex release) is replaced by the fork.

  ## Reverting to the Hex package

  Once the PR is merged and released (a version after 0.3.0), set
  `@archive_source` to `~w(hex mix_completions)`, remove the "Why a fork"
  section and the fork's reference below. The `help` check can stay: the new
  release passes it. An installed fork also passes it, so replace the fork
  by hand with `mix archive.install hex mix_completions --force`.

  The completion script lives outside the project, so it is written directly
  and never shows in Igniter's diff.

  References:

  - https://erikarow.land/articles/mix-completions
  - https://github.com/erikareads/mix_completions
  - https://github.com/erikareads/mix_completions/pull/2
  - https://github.com/toupeira/mix_completions/tree/feat/help-completion
  """

  use Composer.Step,
    summary: "Caches mix task names and installs bash completion for mix",
    action: :gen,
    capability: [:devtools],
    phase: :finalize,
    stability: :experimental,
    tags: [:completions]

  @archive_source ~w(github toupeira/mix_completions branch feat/help-completion)
  @complete_dir "~/.complete"
  @script_file "mix_autocomplete.bash"
  @help_case "[[ $prev == 'help' ]]"
  @cache_file ".mix_complete.cache"
  @legacy_script ".mix_completions.bash"
  @gitignore_entry "\n# mix task completion cache (mix complete)\n#{@cache_file}\n"

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
    if Igniter.exists?(igniter, ".gitignore") do
      Composer.Helpers.update_file_content(igniter, ".gitignore", fn content ->
        if String.contains?(content, @cache_file) do
          content
        else
          String.trim_trailing(content) <> "\n" <> @gitignore_entry
        end
      end)
    else
      Igniter.create_new_file(igniter, ".gitignore", String.trim_leading(@gitignore_entry))
    end
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
