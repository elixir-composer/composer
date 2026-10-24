defmodule Composer.CbStd.Steps.ForceDropTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "force_drop" do
    test "rewrites the ecto.drop alias" do
      mix_exs = """
      defmodule Test.MixProject do
        use Mix.Project

        def project do
          [app: :test, version: "0.1.0", aliases: aliases(), deps: []]
        end

        defp aliases do
          [
            "ecto.reset": ["ecto.drop", "ecto.setup"]
          ]
        end
      end
      """

      igniter =
        test_project(files: %{"mix.exs" => mix_exs})
        |> Igniter.compose_task(Composer.CbStd.Steps.Ecto.ForceDrop)

      assert diff(igniter, only: "mix.exs") =~ "ecto.drop --force-drop"
    end
  end
end
