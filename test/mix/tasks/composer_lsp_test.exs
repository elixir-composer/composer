defmodule Mix.Tasks.Composer.LspTest do
  use ExUnit.Case, async: false

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "without GenLSP: says what to add and exits non-zero" do
    assert catch_exit(Mix.Tasks.Composer.Lsp.run([], false)) == {:shutdown, 1}
    assert_received {:mix_shell, :error, [message]}
    assert message =~ ~s({:gen_lsp, "~> 0.11.4", only: :dev})
    assert message =~ "mix deps.get"
  end

  test "GenLSP is available in composer's own build" do
    assert Composer.LSP.available?()
  end
end
