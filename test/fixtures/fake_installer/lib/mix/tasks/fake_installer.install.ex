defmodule Mix.Tasks.FakeInstaller.Install do
  @moduledoc "Records the arguments it was installed with in installed.txt."
  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task), do: %Igniter.Mix.Task.Info{schema: [greeting: :string]}

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    yes = Enum.count(igniter.args.argv, &(&1 == "--yes"))

    Igniter.create_new_file(
      igniter,
      "installed.txt",
      "greeting=#{igniter.args.options[:greeting]} yes=#{yes}\n"
    )
  end
end
