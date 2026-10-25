defmodule Composer.NestedBook.Steps.Cluster.Dns do
  @moduledoc false
  use Composer.Step, summary: "Writes dns.txt", action: :gen, stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "dns.txt", "dns\n")
end
