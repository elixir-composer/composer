defmodule Composer.OtherBook.Steps.Setup.Credo do
  @moduledoc false
  # Shares its id with fake_book:setup:credo, so an unqualified "setup/credo"
  # is ambiguous when both cookbooks are installed.
  use Composer.Step,
    summary: "Adds Credo for static code analysis",
    action: :add,
    capability: [:devtools],
    phase: :setup,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Igniter.Project.Deps.add_dep(igniter, {:credo, "~> 1.7", only: [:dev, :test], runtime: false})
  end
end
