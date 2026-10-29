defmodule Composer.OtherBook.Steps.Cluster.Gigalixir do
  @moduledoc false
  use Composer.Step,
    summary: "Writes gigalixir.txt",
    action: :add,
    capability: [:deploy],
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "gigalixir.txt", "gigalixir\n")
end
