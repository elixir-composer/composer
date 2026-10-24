defmodule Composer.CbStd.Steps.Phx.MinimalAppLayout do
  @moduledoc "Replaces the `Layouts.app/1` component with a minimal header-and-main layout."
  use Composer.Step,
    summary: "Generates a minimal app layout",
    action: :patch,
    frameworks: [:phoenix, :liveview],
    phase: :setup,
    stability: :stable

  alias Composer.Templates

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    layouts_module = Module.concat([Templates.assigns(igniter).web_module, "Layouts"])

    Templates.replace_function(
      igniter,
      layouts_module,
      :app,
      1,
      template("app_fn.ex.eex"),
      %{},
      warning:
        "#{inspect(layouts_module)} has no app/1 function — skipped generating the " <>
          "minimal app layout. Either it was customized, or phx.new's output has changed."
    )
  end
end
