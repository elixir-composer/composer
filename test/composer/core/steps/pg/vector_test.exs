defmodule Composer.Core.Steps.VectorTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "vector adds dep, postgrex types, config, and extension migration" do
    igniter = Igniter.compose_task(test_project(), Composer.Core.Steps.Pg.Vector)

    assert diff(igniter, only: "mix.exs") =~ ":pgvector"
    assert diff(igniter, only: "lib/test/postgrex_types.ex") =~ "Postgrex.Types.define"
    assert diff(igniter, only: "config/config.exs") =~ "Test.PostgrexTypes"
    assert diff(igniter) =~ "CREATE EXTENSION IF NOT EXISTS vector"
  end

  test "vector reuses an existing add_extensions migration" do
    migration = """
    defmodule Test.Repo.Migrations.AddExtensions do
      use Ecto.Migration

      def up do
        execute "CREATE EXTENSION IF NOT EXISTS citext"
      end

      def down do
        execute "DROP EXTENSION IF EXISTS citext"
      end
    end
    """

    igniter =
      test_project(
        files: %{"priv/repo/migrations/20260101000000_add_extensions.exs" => migration}
      )
      |> Igniter.compose_task(Composer.Core.Steps.Pg.Vector)

    diff = diff(igniter, only: "priv/repo/migrations/20260101000000_add_extensions.exs")
    assert diff =~ "CREATE EXTENSION IF NOT EXISTS vector"
    refute diff(igniter) =~ ~r/\d+_add_extensions\.exs.*\d+_add_extensions\.exs/s
  end
end
