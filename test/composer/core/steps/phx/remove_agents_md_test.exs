defmodule Composer.Core.Steps.RemoveAgentsMdTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "removes AGENTS.md when present" do
    igniter =
      test_project(files: %{"AGENTS.md" => "# Agent guidelines\n"})
      |> Igniter.compose_task(Composer.Core.Steps.Phx.RemoveAgentsMd)

    assert "AGENTS.md" in igniter.rms
  end

  test "no-ops when AGENTS.md is absent" do
    igniter =
      test_project()
      |> Igniter.compose_task(Composer.Core.Steps.Phx.RemoveAgentsMd)

    assert igniter.rms == []
  end
end
