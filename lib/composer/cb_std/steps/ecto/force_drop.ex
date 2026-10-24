defmodule Composer.CbStd.Steps.Ecto.ForceDrop do
  @moduledoc "Updates the `ecto.drop` alias in `mix.exs` to use `--force-drop`."
  use Composer.Step,
    summary: "Updates the ecto.drop alias to use --force-drop",
    action: :config,
    frameworks: [:ecto],
    capability: [:database],
    phase: :finalize,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Composer.Helpers.update_file_content(igniter, "mix.exs", fn content ->
      String.replace(content, "\"ecto.drop\"", "\"ecto.drop --force-drop\"")
    end)
  end
end
