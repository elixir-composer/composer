defmodule Composer.FakeBook.Steps.Ash.Postgres do
  @moduledoc false
  use Composer.Step,
    summary: "Adds AshPostgres",
    action: :add,
    frameworks: [:ash, :ecto],
    capability: [:database],
    phase: :setup,
    stability: :experimental,
    tags: ["postgres"],
    requires: ["fake_book:hello"],
    provides: [:datalayer]

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "postgres.txt", "pg\n")
end
