defmodule Composer.CbStd.Steps.Setup.Gitignore do
  @moduledoc "Adds the expert cache directory to `.gitignore`, creating the file if needed."
  use Composer.Step,
    summary: "Adds expert cache to .gitignore",
    action: :config,
    capability: [:devtools],
    phase: :setup,
    stability: :stable

  @entry "\n# Ignore .expert droppings\n.expert/\n"

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    if Igniter.exists?(igniter, ".gitignore") do
      Composer.Helpers.update_file_content(igniter, ".gitignore", fn content ->
        if String.contains?(content, ".expert") do
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
