defmodule Composer.Core.Steps.Setup.Gitignore do
  @moduledoc "Adds macOS system files to `.gitignore`, creating the file if needed."
  use Composer.Step,
    summary: "Adds macOS system files to .gitignore",
    action: :config,
    capability: [:devtools],
    phase: :setup,
    stability: :stable

  @entry "\n# Ignore macOS system files\n.DS_Store\n"

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    if Igniter.exists?(igniter, ".gitignore") do
      Composer.Helpers.update_file_content(igniter, ".gitignore", fn content ->
        if String.contains?(content, ".DS_Store") do
          content
        else
          String.trim_trailing(content) <> "\n" <> @entry
        end
      end)
    else
      Igniter.create_new_file(igniter, ".gitignore", String.trim_leading(@entry))
    end
  end
end
