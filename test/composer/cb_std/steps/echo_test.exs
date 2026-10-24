defmodule Composer.CbStd.Steps.EchoTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "prints its message and changes nothing" do
    igniter =
      test_project()
      |> Igniter.compose_task(Composer.CbStd.Steps.Echo, ["Hello", "from composer"])

    assert_received {:mix_shell, :info, ["Hello from composer"]}
    assert_unchanged(igniter)
  end

  test "prints an empty line without a message" do
    test_project() |> Igniter.compose_task(Composer.CbStd.Steps.Echo, [])

    assert_received {:mix_shell, :info, [""]}
  end
end
