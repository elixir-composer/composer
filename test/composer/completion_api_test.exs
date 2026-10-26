defmodule Composer.CompletionApiTest do
  use ExUnit.Case, async: true

  alias Composer.Completion

  doctest Composer.Completion

  test "gives each shell's script" do
    for shell <- Completion.shells() do
      assert {:ok, script} = Completion.script(shell)
      assert Completion.script!(shell) == script
    end
  end

  test "an unknown shell is an error" do
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
