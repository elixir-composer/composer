defmodule Composer.Core.Steps.SortDepsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "sort_deps" do
    defp sorted_mix_exs(deps_block) do
      mix_exs = """
      defmodule Test.MixProject do
        use Mix.Project

        def project do
          [app: :test, version: "0.1.0", deps: deps()]
        end

        defp deps do
          [
      #{deps_block}
          ]
        end
      end
      """

      test_project(files: %{"mix.exs" => mix_exs})
      |> Igniter.compose_task(Composer.Core.Steps.Setup.SortDeps)
      |> apply_igniter!()
      |> Map.get(:rewrite)
      |> Rewrite.source!("mix.exs")
      |> Rewrite.Source.get(:content)
    end

    test "sorts alphabetically, preserving multi-line formatting exactly" do
      content =
        sorted_mix_exs("""
              {:phoenix, "~> 1.8.8"},
              {:bandit, "~> 1.5"},
              {:heroicons,
               github: "tailwindlabs/heroicons",
               tag: "v2.2.0",
               sparse: "optimized"},
              {:ecto_sql, "~> 3.13"}\
        """)

      expected =
        Enum.join(
          [
            ~s(      {:bandit, "~> 1.5"},),
            ~s(      {:ecto_sql, "~> 3.13"},),
            ~s(      {:heroicons,),
            ~s(       github: "tailwindlabs/heroicons",),
            ~s(       tag: "v2.2.0",),
            ~s(       sparse: "optimized"},),
            ~s(      {:phoenix, "~> 1.8.8"})
          ],
          "\n"
        )

      assert content =~ expected

      # The file still parses and no dep was lost
      assert {:ok, _} = Code.string_to_quoted(content)
    end

    test "keeps comments attached and never swallows the following dep" do
      content =
        sorted_mix_exs("""
              {:phoenix, "~> 1.8.8"},
              # {:dep_from_hexpm, "~> 0.3.0"},
              {:ecto_sql, "~> 3.13"},
              {:bandit, "~> 1.5"}\
        """)

      # All three real deps survive
      assert content =~ ~s({:phoenix, "~> 1.8.8"})
      assert content =~ ~s({:ecto_sql, "~> 3.13"})
      assert content =~ ~s({:bandit, "~> 1.5"})
      # The comment rides with ecto_sql (the dep it precedes)
      assert content =~ ~r/# \{:dep_from_hexpm, "~> 0\.3\.0"\},\n\s*\{:ecto_sql/
    end

    test "is a no-op on an already sorted list" do
      mix_exs = """
      defmodule Test.MixProject do
        use Mix.Project

        def project do
          [app: :test, version: "0.1.0", deps: deps()]
        end

        defp deps do
          [
            {:bandit, "~> 1.5"},
            {:phoenix, "~> 1.8.8"}
          ]
        end
      end
      """

      test_project(files: %{"mix.exs" => mix_exs})
      |> Igniter.compose_task(Composer.Core.Steps.Setup.SortDeps)
      |> assert_unchanged("mix.exs")
    end

    test "handles UTF-8 and commas inside strings" do
      content =
        sorted_mix_exs("""
              {:phoenix, "~> 1.8.8"},
              # ünïcode cömment
              {:bandit, "~> 1.5", hex: "bandit, the great"}\
        """)

      assert content =~ ~s({:bandit, "~> 1.5", hex: "bandit, the great"})
      assert content =~ "ünïcode cömment"
      assert {:ok, _} = Code.string_to_quoted(content)
    end
  end
end
