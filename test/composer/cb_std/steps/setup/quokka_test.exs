defmodule Composer.CbStd.Steps.QuokkaTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # The formatter plugin is wired up for real now rather than left to a
  # notice, but that needs the dep fetched first, which cannot happen under
  # Igniter.Test — so only the dep is observable here.
  test "quokka adds a dev/test dep" do
    igniter = Igniter.compose_task(test_project(), Composer.CbStd.Steps.Setup.Quokka)

    assert diff(igniter, only: "mix.exs") =~ ":quokka"
    refute Enum.any?(igniter.notices, &(&1 =~ "Add `Quokka`"))
  end
end
