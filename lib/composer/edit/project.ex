defmodule Composer.Edit.Project do
  @moduledoc """
  Project-level names and files in the target app, for steps.
  """

  alias Composer.Edit.Files

  @doc "Returns the camelized app module name (e.g. `\"MyApp\"`)."
  def app_module(igniter) do
    Igniter.Project.Application.app_name(igniter) |> to_string() |> Macro.camelize()
  end

  @doc "Returns the app's Repo module (e.g. `MyApp.Repo`)."
  def repo(igniter) do
    Module.concat([app_module(igniter), "Repo"])
  end

  @doc "Returns the app's web module name (e.g. `\"MyAppWeb\"`)."
  def app_web_module(igniter) do
    app_module(igniter) <> "Web"
  end

  @doc """
  Ensures `entry` is in, or absent from, the project's `.gitignore`,
  creating the file if needed. A wrapper around
  `Composer.Edit.Files.ensure_line/4`.

  Variants of an entry count as the same entry: `.expert`, `.expert/`,
  `/.expert/` and `.expert/*` all match each other. A variant already in
  the file is normalised to `entry` in place rather than doubled, and a
  second run changes nothing.

  ## Options

    * `:comment` - a comment (without the `#`) written above the entry,
      after a blank line, when the entry is added; never added above an
      entry that is already there
    * `:state` - `:present` (default) or `:absent`, which removes every
      variant of the entry

  ## Examples

      Project.gitignore(igniter, ".expert/")
      Project.gitignore(igniter, ".env", comment: "Environment variables")
      Project.gitignore(igniter, ".expert/", state: :absent)
  """
  @spec gitignore(Igniter.t(), String.t(), keyword()) :: Igniter.t()
  def gitignore(igniter, entry, opts \\ []) do
    opts = Keyword.validate!(opts, [:comment, state: :present])
    match = gitignore_match(entry)

    case {opts[:state], opts[:comment]} do
      {:absent, _} ->
        Files.ensure_line(igniter, ".gitignore", nil, match: match, state: :absent)

      {:present, nil} ->
        Files.ensure_line(igniter, ".gitignore", entry, match: match, create: true)

      {:present, comment} ->
        case read_gitignore(igniter) do
          {igniter, nil} ->
            Igniter.create_new_file(igniter, ".gitignore", "# #{comment}\n#{entry}\n")

          {igniter, content} ->
            if content |> String.split("\n") |> Enum.any?(&Regex.match?(match, &1)) do
              Files.ensure_line(igniter, ".gitignore", entry, match: match)
            else
              Files.update(igniter, ".gitignore", &append_group(&1, comment, entry))
            end
        end

      {state, _} ->
        raise ArgumentError, "state: must be :present or :absent, got: #{inspect(state)}"
    end
  end

  # Matches `.expert`, `/.expert`, `.expert/` and `.expert/*` alike.
  defp gitignore_match(entry) do
    core =
      entry
      |> String.trim()
      |> String.trim_leading("/")
      |> String.replace_suffix("/*", "")
      |> String.trim_trailing("/")

    if core == "", do: raise(ArgumentError, "gitignore needs an entry, got: #{inspect(entry)}")

    ~r"^/?#{Regex.escape(core)}(/\*?)?\s*$"
  end

  # The file must be read into the igniter before it is changed, or Igniter
  # would overwrite a file that is on disk but not yet read.
  defp read_gitignore(igniter) do
    if Igniter.exists?(igniter, ".gitignore") do
      igniter = Igniter.include_existing_file(igniter, ".gitignore")
      {igniter, igniter.rewrite |> Rewrite.source!(".gitignore") |> Rewrite.Source.get(:content)}
    else
      {igniter, nil}
    end
  end

  defp append_group(content, comment, entry) do
    group = "# #{comment}\n#{entry}\n"

    case String.trim_trailing(content) do
      "" -> group
      kept -> kept <> "\n\n" <> group
    end
  end
end
