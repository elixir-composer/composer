defmodule Composer.CbStd.Steps.Uuidv7Test do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "uuidv7 adds the dep and rewrites an existing schema module" do
    schema = """
    defmodule Test.Schema do
      defmacro __using__(_) do
        quote do
          @primary_key {:id, :binary_id, autogenerate: true}
          @foreign_key_type :binary_id
        end
      end
    end
    """

    igniter =
      test_project(files: %{"lib/test/schema.ex" => schema})
      |> Igniter.compose_task(Composer.CbStd.Steps.Ecto.Uuidv7)

    assert diff(igniter, only: "mix.exs") =~ ":uuidv7"
    schema_diff = diff(igniter, only: "lib/test/schema.ex")
    assert schema_diff =~ "UUIDv7"
    refute schema_diff =~ "+ |          @primary_key {:id, :binary_id"
  end
end
