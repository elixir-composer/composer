defmodule Mix.Tasks.Composer.Step.RunTest do
  # Sets the :composer application env, read by every task.
  use ExUnit.Case, async: false

  import Igniter.Test

  defmodule RecordingRunner do
    @moduledoc false
    def run(igniter, steps, _opts) do
      send(self(), {:steps, steps})
      igniter
    end
  end

  setup do
    Application.put_env(:composer, :discovery,
      modules: [Composer.FakeBook, Composer.OtherBook],
      local: false
    )

    on_exit(fn ->
      Application.delete_env(:composer, :discovery)
      Application.delete_env(:composer, :runner)
    end)
  end

  defp run(argv), do: Igniter.compose_task(test_project(), "composer.step.run", argv)

  test "runs comma-separated steps as one diff" do
    run(["fake_book:hello,core:setup/gitignore"])
    |> assert_creates("hello.txt", "hello\n")
    |> assert_has_patch(".gitignore", "+ |.DS_Store")
  end

  # Inside composer the project's own cookbook is core, so it wins.
  test "hands the runner internal steps, own cookbook first, with hex: fallbacks" do
    Application.put_env(:composer, :runner, RecordingRunner)
    run(["phx/remove_topbar, ash/postgres, oban, setup/credo"])

    assert_received {:steps,
                     [
                       {:module, Composer.Core.Steps.Phx.RemoveTopbar},
                       {:module, Composer.FakeBook.Steps.Ash.Postgres},
                       {:install, :oban, []},
                       {:module, Composer.Core.Steps.Setup.Credo}
                     ]}
  end

  test "passes arguments after -- to the steps" do
    run(["fake_book:args", "--", "--bar", "baz"])
    |> assert_creates("args.txt", "--bar baz\n")
  end

  test "a hex: ref takes an @ source, and arguments after -- go to its installer" do
    Application.put_env(:composer, :runner, RecordingRunner)

    run(["hex:x@path:../x"])
    assert_received {:steps, [{:install, :x, [source: [path: "../x"]]}]}

    run(["hex:x", "--", "--a", "b"])
    assert_received {:steps, [{:install, :x, [argv: ["--a", "b"]]}]}
  end

  test "requires and ambiguity are checked before anything runs" do
    assert_raise Mix.Error, ~r/composer-fixture-missing-tool/, fn ->
      run(["fake_book:needs_tool"])
    end

    assert_raise Mix.Error, ~r/fake_book:hello\n\s+other_book:hello/, fn -> run(["hello"]) end
  end

  test "requires a reference" do
    assert_raise Mix.Error, ~r/Usage: mix composer.step.run/, fn -> run([]) end
  end
end
