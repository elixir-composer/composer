defmodule Composer.OtherBook.Steps.Setup.Quokka do
  @moduledoc false
  use Composer.Step, summary: "Writes quokka.txt", action: :add, phase: :setup, stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "quokka.txt", "quokka\n")
end
