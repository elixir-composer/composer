defmodule Composer.CbStd.Steps.TidewaveConfigTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "creates .mcp.json pointing at the local Tidewave server" do
    test_project()
    |> Igniter.compose_task(Composer.CbStd.Steps.Tidewave.TidewaveConfig)
    |> assert_creates(".mcp.json")
    |> then(&assert(diff(&1, only: ".mcp.json") =~ "http://localhost:4000/tidewave/mcp"))
  end

  test "leaves an existing .mcp.json alone" do
    test_project(files: %{".mcp.json" => "{}\n"})
    |> Igniter.compose_task(Composer.CbStd.Steps.Tidewave.TidewaveConfig)
    |> assert_unchanged(".mcp.json")
  end
end
