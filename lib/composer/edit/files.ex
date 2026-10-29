defmodule Composer.Edit.Files do
  @moduledoc """
  Changes to file content in the target app, for steps.

  Every function takes the igniter first and the path second, returns the
  igniter, and stages its change in the igniter, so it shows in the diff,
  in a dry run and in the composer's commit.
  """

  @doc "Updates a file's raw content with a transformation function."
  def update(igniter, path, transform) do
    Igniter.update_file(igniter, path, fn source ->
      source
      |> Rewrite.Source.get(:content)
      |> transform.()
      |> then(&Rewrite.Source.update(source, :content, &1))
    end)
  end

  @doc """
  Updates a file's content, adding a loud warning instead of silently
  no-oping when the transformation changes nothing or the file is missing.

  Steps that pattern-match against `phx.new` output should use this so that
  drift in Phoenix's generators surfaces as a warning instead of silence.
  """
  def update_checked(igniter, path, transform, warning) do
    if Igniter.exists?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)
      source = Rewrite.source!(igniter.rewrite, path)
      content = Rewrite.Source.get(source, :content)

      if transform.(content) == content do
        Igniter.add_warning(igniter, warning)
      else
        update(igniter, path, transform)
      end
    else
      Igniter.add_warning(igniter, "#{path} not found — #{warning}")
    end
  end

  @doc """
  Creates a file unless it already exists, in the project or on disk.

  Use this rather than `Igniter.create_new_file/4` with `on_exists: :skip`,
  which overwrites a file that exists on disk but has not been read into the
  igniter yet.
  """
  def create_unless_exists(igniter, path, contents) do
    if Igniter.exists?(igniter, path),
      do: igniter,
      else: Igniter.create_new_file(igniter, path, contents)
  end
end
