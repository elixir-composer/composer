defmodule Composer.FakeBook.Steps.Args do
  @moduledoc false
  # Records the argv it was given, to test `--` pass-through.
  use Composer.Step, summary: "Writes its argv to args.txt", action: :gen, stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Igniter.create_new_file(igniter, "args.txt", Enum.join(igniter.args.argv, " ") <> "\n")
  end
end
