defmodule Composer.OtherBook.Steps.Setup.Gitignore do
  @moduledoc false
  use Composer.Step,
    summary: "Adds expert cache to .gitignore",
    action: :config,
    capability: [:devtools],
    phase: :setup,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Igniter.create_or_update_file(igniter, ".gitignore", ".expert/\n", fn source ->
      content = Rewrite.Source.get(source, :content)

      if String.contains?(content, ".expert/") do
        source
      else
        Rewrite.Source.update(source, :content, String.trim_trailing(content) <> "\n.expert/\n")
      end
    end)
  end
end
