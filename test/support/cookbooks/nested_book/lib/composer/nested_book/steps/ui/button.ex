defmodule Composer.NestedBook.Steps.Ui.Button do
  @moduledoc false
  use Composer.Step, summary: "Writes button.txt", action: :gen, stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "button.txt", "button\n")
end
