defmodule Composer.CbStd.Steps.ExsyncTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "exsync adds a dev-only dep and dev config" do
    igniter = Igniter.compose_task(test_project(), Composer.CbStd.Steps.Setup.Exsync)

    assert diff(igniter, only: "mix.exs") =~ ":exsync"
    assert diff(igniter, only: "config/dev.exs") =~ "src_monitor"
  end
end
