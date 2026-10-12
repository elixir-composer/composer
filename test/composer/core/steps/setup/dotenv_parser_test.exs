defmodule Composer.Core.Steps.DotenvParserTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "dotenv_parser adds dep, .env, runtime config, and gitignore entry" do
    igniter = Igniter.compose_task(test_project(), Composer.Core.Steps.Setup.DotenvParser)

    assert diff(igniter, only: "mix.exs") =~ ":dotenv_parser"
    assert_creates(igniter, ".env", "VARIABLE=value")
    assert diff(igniter, only: "config/runtime.exs") =~ "DotenvParser.load_file"
    assert diff(igniter, only: ".gitignore") =~ ".env"
  end

  test "dotenv_parser appends config when runtime.exs lacks import Config" do
    runtime = """
    if System.get_env("PHX_SERVER") do
      :ok
    end
    """

    igniter =
      test_project(files: %{"config/runtime.exs" => runtime})
      |> Igniter.compose_task(Composer.Core.Steps.Setup.DotenvParser)

    assert diff(igniter, only: "config/runtime.exs") =~ "DotenvParser.load_file"
  end
end
