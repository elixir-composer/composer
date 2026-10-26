defmodule Mix.Tasks.Composer.CompletionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Composer.Completion

  doctest Composer.Completion

  test "prints a shell's script" do
    for shell <- Completion.shells() do
      output = capture_io(fn -> Mix.Tasks.Composer.Completion.run([shell]) end)
      assert output == Completion.script!(shell)
    end
  end

  test "an unknown shell raises the usage" do
    assert_raise Mix.Error, "Usage: mix composer.completion bash|zsh|fish", fn ->
      Mix.Tasks.Composer.Completion.run(["nope"])
    end

    assert Completion.script("nope") == {:error, :unknown_shell}
    assert_raise ArgumentError, fn -> Completion.script!("nope") end
  end

  test "the scripts ship in the package" do
    assert "priv" in Mix.Project.config()[:package][:files]
    assert {:ok, "# Bash completion" <> _} = Completion.script("bash")
  end

  test "every shell has a default path under ~" do
    for shell <- Completion.shells() do
      assert "~/" <> _ = Completion.default_path(shell)
    end
  end
end
