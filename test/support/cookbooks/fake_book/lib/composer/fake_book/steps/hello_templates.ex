defmodule Composer.FakeBook.Steps.HelloTemplates do
  @moduledoc false
  use Composer.Step, summary: "Copies a template", action: :gen, stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Composer.Templates.copy_file(igniter, template("greeting.txt.eex"), "greeting.txt")
  end
end
