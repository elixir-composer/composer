if Code.ensure_loaded?(Composer) do
  defmodule Composer.FakeFramework.Steps.Hi do
    @moduledoc false
    use Composer.Step, summary: "Writes hi.txt", action: :gen, stability: :stable

    @impl Igniter.Mix.Task
    def igniter(igniter),
      do: Composer.Templates.copy_file(igniter, template("hi.txt.eex"), "hi.txt")
  end
end
