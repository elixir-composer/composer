defmodule Composer.CbStd.Steps.CredoTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "adds credo as a dev/test dependency" do
    diff =
      test_project()
      |> Igniter.compose_task(Composer.CbStd.Steps.Setup.Credo)
      |> diff(only: "mix.exs")

    assert diff =~ ":credo"
    assert diff =~ "only: [:dev, :test]"
    assert diff =~ "runtime: false"
  end
end
