defmodule Composer.FakeDep.Steps.Hi do
  @moduledoc false
  use Composer.Step, summary: "Writes hi.txt", action: :gen, stability: :stable

  # The template sits beside this step, in _hi/, so it is read from the installed
  # dependency's source.
  @impl Igniter.Mix.Task
  def igniter(igniter), do: Composer.Templates.copy_file(igniter, template("hi.txt.eex"), "hi.txt")
end
