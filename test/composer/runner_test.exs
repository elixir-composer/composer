defmodule Composer.RunnerTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Composer.Runner

  test "applies module steps in order" do
    igniter =
      Runner.run(test_project(), [
        {:module, Composer.CbStd.Steps.Setup.Gitignore},
        {:module, Composer.CbStd.Steps.Setup.Credo}
      ])

    assert diff(igniter, only: ".gitignore") =~ ".expert/"
    assert diff(igniter, only: "mix.exs") =~ ":credo"
  end

  test "{:module, m, argv} passes argv to the step" do
    defmodule ArgvStep do
      use Igniter.Mix.Task

      @impl Igniter.Mix.Task
      def info(_argv, _parent), do: %Igniter.Mix.Task.Info{schema: [name: :string]}

      @impl Igniter.Mix.Task
      def igniter(igniter) do
        Igniter.create_new_file(igniter, "name.txt", igniter.args.options[:name] <> "\n")
      end
    end

    test_project()
    |> Runner.run([{:module, ArgvStep, ["--name", "pat"]}])
    |> assert_creates("name.txt", "pat\n")
  end

  test "non-Igniter {:task, ...} steps warn instead of silently no-oping" do
    igniter = Runner.run(test_project(), [{:task, "format", []}])

    assert Enum.any?(igniter.warnings, &(&1 =~ "not an Igniter task"))
  end

  test "{:install, pkg, opts} resolves in-run rather than queueing a subprocess" do
    igniter = Runner.run(test_project(), [{:install, :ash, []}])

    # Installs are composed into this run, so nothing is handed to a
    # subprocess — the old `igniter.install` queueing is gone.
    refute Enum.any?(igniter.tasks, fn {task, _argv} -> task == "igniter.install" end)
  end

  test "installs/1 lists the packages to fetch up front, once each" do
    steps = [
      {:install, :ash, []},
      {:module, Composer.CbStd.Steps.Setup.Credo},
      {:install, :ash, [argv: ["--x"]]},
      {:install, :tidewave, [dep: [only: [:dev]]]}
    ]

    assert Runner.installs(steps) == [:ash, :tidewave]
  end

  test "argv for a package that ships no installer warns" do
    igniter = Runner.run(test_project(), [{:install, :no_such_pkg, [argv: ["--x", "y"]]}])

    assert [warning] = Enum.filter(igniter.warnings, &(&1 =~ "hex:no_such_pkg"))
    assert warning =~ "ships no installer, so its argv (--x y) was not used"
    # The golden CI job fails on these no-op phrases.
    refute warning =~ ~r/Nothing was modified|skipped adding|skipped removing|was skipped/
  end

  test "install_label/2 shows the source and the installer argv" do
    assert Runner.install_label(:ash, []) == "hex:ash"

    assert Runner.install_label("my_lib", source: [path: "../my_lib"]) ==
             "hex:my_lib (path ../my_lib)"

    assert Runner.install_label(:x, source: [github: "a/b", ref: "main"]) ==
             "hex:x (github a/b, ref main)"

    assert Runner.install_label(:ash_authentication,
             argv: ["--auth-strategy", "password"],
             source: [version: "~> 3.5"],
             dep: [only: [:dev]]
           ) == "hex:ash_authentication (version ~> 3.5) --auth-strategy password"
  end

  describe "dep_spec/2" do
    test "is nil without a source, so the latest Hex version is looked up" do
      assert Runner.dep_spec("ash", []) == nil
      assert Runner.dep_spec("ash", argv: ["--x"], dep: [only: [:dev]]) == nil
    end

    test "builds each source kind" do
      assert Runner.dep_spec("ash", source: [version: "~> 3.5"]) == {:ash, "~> 3.5"}

      assert Runner.dep_spec("oban.oban_pro", source: [version: "~> 1.0"]) ==
               {:oban_pro, "~> 1.0", repo: "oban"}

      assert Runner.dep_spec("x", source: [github: "a/b"]) == {:x, github: "a/b"}

      assert Runner.dep_spec("x", source: [github: "a/b", ref: "main"]) ==
               {:x, github: "a/b", ref: "main"}

      for opt <- [ref: "abc", branch: "b", tag: "v1"] do
        assert Runner.dep_spec("x",
                 source: [git: "https://h/x.git", sparse: "s", submodules: true] ++ [opt]
               ) ==
                 {:x, [git: "https://h/x.git", sparse: "s", submodules: true] ++ [opt]}
      end

      assert Runner.dep_spec("my_lib", source: [path: "../my_lib"]) ==
               {:my_lib, path: "../my_lib", override: true}
    end
  end

  describe "merge_dep_opts/2" do
    test "leaves a dep alone without options" do
      for dep <- [{:a, "~> 1.0"}, {:a, path: "x"}, {:a, "~> 1.0", repo: "r"}] do
        assert Runner.merge_dep_opts(dep, []) == dep
      end
    end

    test "folds only: and runtime: into every shape, unwrapping a single env" do
      opts = [only: [:dev], runtime: false]

      assert Runner.merge_dep_opts({:a, "~> 1.0"}, opts) ==
               {:a, "~> 1.0", only: :dev, runtime: false}

      assert Runner.merge_dep_opts({:a, path: "x", override: true}, opts) ==
               {:a, path: "x", override: true, only: :dev, runtime: false}

      assert Runner.merge_dep_opts({:a, "~> 1.0", repo: "r"}, only: [:dev, :test]) ==
               {:a, "~> 1.0", repo: "r", only: [:dev, :test]}
    end
  end

  test "{:queue, ...} queues the task with exactly its args plus --yes" do
    igniter = Runner.run(test_project(), [{:queue, "some.task", ["oban_pro"]}])

    # The run's own flags must not leak into subprocess argv (strict option
    # parsers reject them).
    assert igniter.tasks == [{"some.task", ["oban_pro", "--yes"]}]
  end

  describe "oban_web patch" do
    test "drops parens from the router's oban_dashboard call and adds import_deps" do
      igniter =
        Runner.run(
          test_project(
            files: %{
              "lib/test_web/router.ex" => """
              defmodule TestWeb.Router do
                use TestWeb, :router

                scope "/" do
                  oban_dashboard("/oban")
                end
              end
              """
            }
          ),
          [{:install, :oban_web, []}]
        )

      router_diff = diff(igniter, only: "lib/test_web/router.ex")
      assert router_diff =~ "+ |    oban_dashboard \"/oban\""

      assert diff(igniter, only: ".formatter.exs") =~ ":oban_web"
    end
  end

  describe "Phoenix version guard" do
    defp project_with_phoenix(requirement) do
      test_project(
        files: %{
          "mix.exs" => """
          defmodule Test.MixProject do
            use Mix.Project

            def project do
              [app: :test, version: "0.1.0", deps: deps()]
            end

            defp deps do
              [
                {:phoenix, "#{requirement}"}
              ]
            end
          end
          """
        }
      )
    end

    @steps [{:module, Composer.CbStd.Steps.Setup.Gitignore}]

    test "warns when the app's Phoenix is older than the supported series" do
      igniter = Runner.run(project_with_phoenix("~> 1.7.14"), @steps)

      assert Enum.any?(igniter.warnings, &(&1 =~ "supports only the latest stable Phoenix"))
    end

    test "does not warn on the supported series" do
      igniter = Runner.run(project_with_phoenix("~> 1.8.8"), @steps)

      refute Enum.any?(igniter.warnings, &(&1 =~ "supports only the latest stable Phoenix"))
    end

    test "does not warn when Phoenix is not a dependency" do
      igniter = Runner.run(test_project(), @steps)

      refute Enum.any?(igniter.warnings, &(&1 =~ "supports only the latest stable Phoenix"))
    end
  end
end
