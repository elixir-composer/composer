defmodule Composer.CbStd.Steps.MinimalAppLayoutTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # The exact output, so rendering the layout from a template (rather than
  # a heredoc) is proven not to change the diff.
  test "replaces app/1 with the minimal layout" do
    layouts = """
    defmodule TestWeb.Layouts do
      use TestWeb, :html

      def app(assigns) do
        ~H\"\"\"
        <main class="px-4">{render_slot(@inner_block)}</main>
        \"\"\"
      end

      def other(assigns), do: assigns
    end
    """

    expected = """
    defmodule TestWeb.Layouts do
      use TestWeb, :html

      def app(assigns) do
        ~H\"\"\"
        <header class="flex gap-4 items-center px-4 py-3">
          <a href="/" class="font-semibold">Test</a>
          <div class="flex-1"></div>
          <.button class="bg-black font-semibold h-8 px-4 rounded text-sm text-white">
            Primary Action
          </.button>
        </header>
        <main>
          {render_slot(@inner_block)}
        </main>
        <.flash_group flash={@flash} />
        \"\"\"
      end

      def other(assigns), do: assigns
    end
    """

    igniter =
      test_project(files: %{"lib/test_web/components/layouts.ex" => layouts})
      |> Igniter.compose_task(Composer.CbStd.Steps.Phx.MinimalAppLayout)

    content =
      igniter.rewrite
      |> Rewrite.source!("lib/test_web/components/layouts.ex")
      |> Rewrite.Source.get(:content)

    assert content == expected
  end

  test "minimal_app_layout warns instead of crashing when app/1 is missing" do
    layouts = """
    defmodule TestWeb.Layouts do
      def something_else(assigns), do: assigns
    end
    """

    igniter =
      test_project(files: %{"lib/test_web/components/layouts.ex" => layouts})
      |> Igniter.compose_task(Composer.CbStd.Steps.Phx.MinimalAppLayout)

    assert Enum.any?(igniter.warnings, &(&1 =~ "has no app/1 function"))
  end
end
