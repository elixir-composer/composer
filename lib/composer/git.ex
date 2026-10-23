defmodule Composer.Git do
  @moduledoc """
  Git support for `mix composer.recipe.run`: the pre-flight status check,
  the commit message, and the commit itself.
  """

  @subject_prefix "composer: apply recipe "
  @subject_max 71

  @doc """
  Reports the state of the work tree containing `dir`.

  Untracked files count as dirty; ignored files do not. A missing `git`
  binary is reported as `:not_a_repo`.
  """
  @spec status(Path.t()) :: :not_a_repo | :clean | :dirty
  def status(dir) do
    case git(dir, ["rev-parse", "--is-inside-work-tree"]) do
      {"true\n", 0} ->
        case git(dir, ["status", "--porcelain"]) do
          {"", 0} -> :clean
          _ -> :dirty
        end

      _ ->
        :not_a_repo
    end
  end

  @doc """
  Builds the commit message for a run of `recipe`.

  `info` carries `:flags` (the flag names that were passed). The subject
  stays under 72 characters; the body is plain lines, numbered steps, no
  bullets.
  """
  @spec message(String.t(), %{flags: [atom()]}, [
          Composer.Resolver.entry()
        ]) :: String.t()
  def message(recipe, %{flags: flags}, entries) do
    flags =
      case flags do
        [] -> "(none)"
        flags -> Enum.map_join(flags, " ", &("--" <> String.replace(to_string(&1), "_", "-")))
      end

    steps =
      case entries do
        [] ->
          "(none)"

        entries ->
          entries
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {entry, n} ->
            "#{n}. #{entry.label} [#{entry.origin || "command line"}]"
          end)
      end

    """
    #{subject(recipe)}

    Flags: #{flags}

    Steps:
    #{steps}
    """
  end

  defp subject(recipe) do
    name = recipe
    room = @subject_max - String.length(@subject_prefix)

    name =
      if String.length(name) > room,
        do: String.slice(name, 0, room - 3) <> "...",
        else: name

    @subject_prefix <> name
  end

  @doc """
  Stages everything and commits with the message in `message_file`.

  Returns `{:ok, output}` on a commit, `:nothing_to_commit` when the tree had
  no changes, or `{:error, output}`.
  """
  @spec commit(Path.t(), Path.t()) ::
          {:ok, String.t()} | :nothing_to_commit | {:error, String.t()}
  def commit(dir, message_file) do
    with {_, 0} <- git(dir, ["add", "-A"]) do
      case git(dir, ["status", "--porcelain"]) do
        {"", 0} ->
          :nothing_to_commit

        _ ->
          case git(dir, ["commit", "--quiet", "-F", message_file]) do
            {output, 0} -> {:ok, output}
            {output, _} -> {:error, output}
          end
      end
    else
      {output, _} -> {:error, output}
    end
  end

  defp git(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  rescue
    ErlangError -> {"git not found", 127}
  end
end
