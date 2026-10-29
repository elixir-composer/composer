defmodule Composer.OtherBook.Steps.Setup.SortDeps do
  @moduledoc false
  use Composer.Step,
    summary: "Writes sort_deps.txt",
    action: :patch,
    phase: :finalize,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "sort_deps.txt", "sorted\n")
end
