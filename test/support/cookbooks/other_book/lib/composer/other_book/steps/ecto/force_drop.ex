defmodule Composer.OtherBook.Steps.Ecto.ForceDrop do
  @moduledoc false
  use Composer.Step,
    summary: "Updates the ecto.drop alias to use --force-drop",
    action: :config,
    frameworks: [:ecto],
    capability: [:database],
    phase: :finalize,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Igniter.update_file(igniter, "mix.exs", fn source ->
      content = Rewrite.Source.get(source, :content)

      Rewrite.Source.update(
        source,
        :content,
        String.replace(content, ~s("ecto.drop"), ~s("ecto.drop --force-drop"))
      )
    end)
  end
end
