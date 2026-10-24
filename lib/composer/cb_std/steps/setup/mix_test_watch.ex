defmodule Composer.CbStd.Steps.Setup.MixTestWatch do
  @moduledoc "Adds `mix_test_watch` to automatically run tests on file changes."
  use Composer.Step,
    summary: "Adds mix_test_watch for running tests on file changes",
    action: :add,
    capability: [:testing, :devtools],
    phase: :setup,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    {package, version} = Composer.Versions.latest_hex_dep(:mix_test_watch)

    igniter
    |> Igniter.Project.Deps.add_dep({package, version, only: [:dev, :test], runtime: false})
    |> Igniter.add_notice("Run `mix test.watch` to run tests on file changes")
  end
end
