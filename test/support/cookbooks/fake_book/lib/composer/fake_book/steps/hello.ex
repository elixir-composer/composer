defmodule Composer.FakeBook.Steps.Hello do
  use Composer.Step,
    summary: "Writes hello.txt",
    action: :gen,
    phase: :setup,
    stability: :stable,
    tags: [:greeting]

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "hello.txt", "hello\n")
end
