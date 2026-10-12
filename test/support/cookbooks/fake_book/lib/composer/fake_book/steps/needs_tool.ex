defmodule Composer.FakeBook.Steps.NeedsTool do
  @moduledoc false
  use Composer.Step,
    summary: "Needs a missing executable",
    action: :add,
    stability: :stable,
    requires: [{:executable, "composer-fixture-missing-tool"}, {:package, :jason, "~> 99.0"}]

  @impl Igniter.Mix.Task
  def igniter(igniter), do: igniter
end
