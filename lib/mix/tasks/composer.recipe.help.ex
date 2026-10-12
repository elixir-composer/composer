defmodule Mix.Tasks.Composer.Recipe.Help do
  # No @shortdoc, so `mix help` leaves this alias out.
  @moduledoc "An alias for `mix composer.recipe.show`."

  use Mix.Task

  @impl Mix.Task
  defdelegate run(argv), to: Mix.Tasks.Composer.Recipe.Show
end
