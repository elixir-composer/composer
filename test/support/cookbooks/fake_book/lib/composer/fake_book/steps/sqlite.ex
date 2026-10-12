defmodule Composer.FakeBook.Steps.Sqlite do
  @moduledoc false
  use Composer.Step,
    summary: "Adds SQLite",
    action: :add,
    phase: :cleanup,
    stability: :stable,
    provides: [:datalayer],
    conflicts: [:datalayer]

  @impl Igniter.Mix.Task
  def igniter(igniter), do: igniter
end
