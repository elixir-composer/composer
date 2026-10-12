defmodule Composer.Core.Steps.TailwindFormatterTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "tailwind_formatter" do
    # Regression: the step arms attribute_formatters in .formatter.exs
    # immediately, but the formatter source is only in-memory until the run
    # applies — unless the step loads the module itself, every HEEx format
    # for the rest of the run logs "module ... is not loaded and could not
    # be found" and skips class sorting.
    test "loads the class formatter module during the run" do
      igniter = Igniter.compose_task(test_project(), Composer.Core.Steps.Phx.TailwindFormatter)

      assert Code.ensure_loaded?(TestWeb.Formatters.ClassFormatter)
      assert diff(igniter, only: ".formatter.exs") =~ "attribute_formatters"
    end

    test "loaded formatter sorts classes, state prefixes last" do
      Igniter.compose_task(test_project(), Composer.Core.Steps.Phx.TailwindFormatter)

      # Resolved at runtime — the module only exists once the step compiles it.
      formatter = Module.concat([TestWeb, Formatters, ClassFormatter])

      assert {"class", {:string, "flex p-2 hover:bg-red-500", []}, %{}} =
               formatter.render_attribute(
                 {"class", {:string, "p-2 hover:bg-red-500 flex", []}, %{}},
                 []
               )
    end
  end

  describe "re-runs" do
    test "tailwind_formatter is idempotent instead of crashing on re-run" do
      igniter =
        test_project()
        |> Igniter.compose_task(Composer.Core.Steps.Phx.TailwindFormatter)
        |> apply_igniter!()
        |> Igniter.compose_task(Composer.Core.Steps.Phx.TailwindFormatter)

      assert_unchanged(igniter, ".formatter.exs")
    end
  end
end
