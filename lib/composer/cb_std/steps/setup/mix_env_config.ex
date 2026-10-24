defmodule Composer.CbStd.Steps.Setup.MixEnvConfig do
  @moduledoc "Adds `config :app, env: Mix.env()` to `config.exs` so the environment is readable at runtime."
  use Composer.Step,
    summary: "Exposes Mix.env() in app config",
    action: :config,
    phase: :setup,
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app_name = Igniter.Project.Application.app_name(igniter)

    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      app_name,
      [:env],
      {:code, quote(do: Mix.env())}
    )
  end
end
