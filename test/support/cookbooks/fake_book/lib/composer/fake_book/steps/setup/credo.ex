defmodule Composer.FakeBook.Steps.Setup.Credo do
  @moduledoc false
  # Shares its id with cb_std:setup:credo, so an unqualified "setup/credo" is
  # ambiguous when this cookbook is installed.
  use Composer.Step, summary: "A second credo step", action: :add, stability: :beta

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "credo.txt", "fake\n")
end
