defmodule Composer.OtherBook.Steps.Cluster.Libcluster do
  @moduledoc false
  use Composer.Step,
    summary: "Writes libcluster.txt",
    action: :add,
    capability: [:deploy],
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "libcluster.txt", "libcluster\n")
end
