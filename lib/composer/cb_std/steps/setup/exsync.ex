defmodule Composer.CbStd.Steps.Setup.Exsync do
  @moduledoc "Adds `exsync` to reload modules on file changes."
  use Composer.Step,
    summary: "Adds ExSync for auto-recompilation",
    action: :add,
    capability: [:devtools],
    phase: :setup,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    igniter
    |> add_dep()
    |> edit_config()
  end

  defp add_dep(igniter) do
    {package, version} = Composer.Versions.latest_hex_dep(:exsync)
    Igniter.Project.Deps.add_dep(igniter, {package, version, only: :dev})
  end

  defp edit_config(igniter) do
    Igniter.Project.Config.configure(igniter, "dev.exs", :exsync, [:src_monitor], true)
  end
end
