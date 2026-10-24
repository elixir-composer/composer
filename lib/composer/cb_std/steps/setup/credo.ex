defmodule Composer.CbStd.Steps.Setup.Credo do
  @moduledoc "Adds `credo` as a dev/test dependency."
  use Composer.Step,
    summary: "Adds Credo for static code analysis",
    action: :add,
    capability: [:devtools],
    phase: :setup,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    {package, version} = Composer.Versions.latest_hex_dep(:credo)

    Igniter.Project.Deps.add_dep(igniter, {package, version, only: [:dev, :test], runtime: false})
  end
end
