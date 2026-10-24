defmodule Composer.CbStd.Steps.RemixiconsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @app_css """
  @import "tailwindcss" source(none);
  @plugin "../vendor/heroicons";
  """

  @core_components """
  defmodule TestWeb.CoreComponents do
    use Phoenix.Component

    def icon(%{name: "hero-" <> _} = assigns) do
      ~H\"\"\"
      <span class={[@name, @class]} />
      \"\"\"
    end
  end
  """

  defp run do
    test_project(
      files: %{
        "assets/css/app.css" => @app_css,
        "lib/test_web/components/core_components.ex" => @core_components
      }
    )
    |> Igniter.compose_task(Composer.CbStd.Steps.Phx.Remixicons)
  end

  test "adds the dep, the Tailwind plugin and the CSS import" do
    igniter = run()

    assert diff(igniter, only: "mix.exs") =~ "Remix-Design/RemixIcon"
    assert_creates(igniter, "assets/vendor/remixicons.js")
    assert diff(igniter, only: "assets/css/app.css") =~ ~s(@plugin "../vendor/remixicons";)
  end

  test "adds a remix- icon clause after the heroicons one" do
    diff = diff(run(), only: "lib/test_web/components/core_components.ex")

    assert diff =~ ~s(def icon(%{name: "remix-" <> _} = assigns\))
  end
end
