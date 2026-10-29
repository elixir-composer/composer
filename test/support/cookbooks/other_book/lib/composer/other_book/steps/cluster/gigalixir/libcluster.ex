defmodule Composer.OtherBook.Steps.Cluster.Gigalixir.Libcluster do
  @moduledoc false
  use Composer.Step,
    summary: "Writes gigalixir_libcluster.txt",
    action: :add,
    capability: [:deploy],
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter),
    do: Igniter.create_new_file(igniter, "gigalixir_libcluster.txt", "gigalixir_libcluster\n")
end
