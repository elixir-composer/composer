defmodule Composer.CbStd.Steps.Tidewave.TidewaveConfig do
  @moduledoc """
  Creates `.mcp.json` pointing at a local Tidewave MCP server.

  This only wires up the MCP config file; it does not add the `tidewave`
  dependency or plug. Use `"hex:tidewave"` for the full upstream
  installer, or run this step afterward if you only need the MCP config.
  """
  use Composer.Step,
    summary: "Adds a Tidewave MCP server config",
    action: :add,
    capability: [:ai, :devtools],
    phase: :setup,
    stability: :stable,
    requires: ["hex:tidewave"]

  @content """
  {
    "mcpServers": {
      "tidewave": {
        "type": "http",
        "url": "http://localhost:4000/tidewave/mcp"
      }
    }
  }
  """

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    if Igniter.exists?(igniter, ".mcp.json") do
      igniter
    else
      Igniter.create_new_file(igniter, ".mcp.json", @content)
    end
  end
end
