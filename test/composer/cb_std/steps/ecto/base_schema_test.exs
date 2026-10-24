defmodule Composer.CbStd.Steps.BaseSchemaTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "schema" do
    test "generates with :binary_id by default" do
      igniter = Igniter.compose_task(test_project(), Composer.CbStd.Steps.Ecto.BaseSchema)

      assert diff(igniter, only: "lib/test/schema.ex") =~
               "@primary_key {:id, :binary_id, autogenerate: true}"
    end

    test "uses UUIDv7 when the uuidv7 dep is present" do
      igniter =
        test_project()
        |> Igniter.compose_task(Composer.CbStd.Steps.Ecto.Uuidv7)
        |> Igniter.compose_task(Composer.CbStd.Steps.Ecto.BaseSchema)

      assert diff(igniter, only: "lib/test/schema.ex") =~
               "@primary_key {:id, UUIDv7, autogenerate: true}"
    end
  end
end
