defmodule Composer.FakeBook.Steps.DynamicTemplates do
  @moduledoc false
  use Composer.Step,
    summary: "Copies a template named at run time",
    action: :gen,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    name = "one"
    Composer.Templates.copy_file(igniter, template("#{name}.txt"), "#{name}.txt")
  end
end
