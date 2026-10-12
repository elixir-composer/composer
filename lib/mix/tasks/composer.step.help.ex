defmodule Mix.Tasks.Composer.Step.Help do
  # No @shortdoc, so `mix help` leaves this alias out.
  @moduledoc "An alias for `mix composer.step.show`."

  use Mix.Task

  @impl Mix.Task
  defdelegate run(argv), to: Mix.Tasks.Composer.Step.Show
end
