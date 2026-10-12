defmodule Composer.Core.Steps.ExtensionsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "extensions" do
    test "generates the extensions migration" do
      igniter = Igniter.compose_task(test_project(), Composer.Core.Steps.Pg.Extensions)

      diff = diff(igniter)
      assert diff =~ "add_extensions.exs"
      assert diff =~ "CREATE EXTENSION IF NOT EXISTS citext"
      assert diff =~ "f_unaccent"
    end
  end
end
