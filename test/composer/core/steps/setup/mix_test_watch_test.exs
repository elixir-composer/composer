defmodule Composer.Core.Steps.MixTestWatchTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "mix_test_watch adds a dev/test dep and a notice" do
    igniter = Igniter.compose_task(test_project(), Composer.Core.Steps.Setup.MixTestWatch)

    assert diff(igniter, only: "mix.exs") =~ ":mix_test_watch"
    assert Enum.any?(igniter.notices, &(&1 =~ "test.watch"))
  end
end
