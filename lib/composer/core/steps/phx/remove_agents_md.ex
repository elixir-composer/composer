defmodule Composer.Core.Steps.Phx.RemoveAgentsMd do
  @moduledoc "Removes the `AGENTS.md` file that `phx.new` generates."
  use Composer.Step,
    summary: "Removes the AGENTS.md file",
    action: :remove,
    frameworks: [:phoenix],
    phase: :cleanup,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    if Igniter.exists?(igniter, "AGENTS.md") do
      Igniter.rm(igniter, "AGENTS.md")
    else
      igniter
    end
  end
end
