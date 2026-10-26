defmodule ComposerNew.PlanTest do
  use ExUnit.Case, async: true

  alias ComposerNew.{Command, Plan}

  doctest ComposerNew.Plan

  @env %{cwd: "/work", home: "/home/me", version: "0.3.0"}

  defp build!(argv) do
    assert {:ok, plan} = Plan.build(argv, @env)
    plan
  end

  # Each command as {cd, "cmd args..."}, or the rm_rf tuple.
  defp commands(argv) do
    for command <- build!(argv).commands do
      case command do
        {:rm_rf, dir} -> {:rm_rf, dir}
        %Command{cd: cd} = command -> {cd, Command.to_string(command)}
      end
    end
  end

  defp record(dir, message) do
    [
      {dir, "git init --quiet"},
      {dir, "git add -A"},
      {dir, "git commit --quiet -m " <> Command.escape(message)}
    ]
  end

  describe "the design's examples" do
    test "hex, with a base generator" do
      argv = ~w(my_app --recipe cb_lab/lv/base --with phx.new --with-args=--no-ecto)

      assert commands(argv) ==
               [
                 {nil,
                  "mix igniter.new my_app --no-git --yes --with phx.new --with-args=--no-ecto"},
                 {"/work/my_app",
                  "mix composer_new.install 'composer@~> 0.3,cb_lab' --only dev,test --yes"}
               ] ++
                 record(
                   "/work/my_app",
                   "mix composer.new my_app --recipe cb_lab/lv/base --with phx.new " <>
                     "--with-args=--no-ecto"
                 ) ++
                 [{"/work/my_app", "mix composer.recipe.run cb_lab/lv/base"}]
    end

    test "github, default branch" do
      argv = ~w(my_app --cookbook cb_lab@github:elixir-composer/cb_lab --recipe cb_lab/lv/base)

      assert Enum.at(commands(argv), 1) ==
               {"/work/my_app",
                "mix composer_new.install 'composer@~> 0.3,cb_lab@github:elixir-composer/cb_lab' " <>
                  "--only dev,test --yes"}

      assert List.last(commands(argv)) ==
               {"/work/my_app", "mix composer.recipe.run cb_lab/lv/base"}
    end

    test "github, pinned" do
      plan =
        build!(
          ~w(my_app --cookbook cb_lab@github:elixir-composer/cb_lab@v0.3.0 --recipe cb_lab/lv/base)
        )

      assert plan.summary.deps == [
               "composer@~> 0.3",
               "cb_lab@github:elixir-composer/cb_lab@v0.3.0"
             ]

      assert [%{name: "cb_lab", source: "github:elixir-composer/cb_lab@v0.3.0", hex?: false}] =
               plan.summary.cookbooks

      assert plan.summary.recipe == "cb_lab/lv/base"
    end

    test "local path, with phx.new (the gen_lv case)" do
      argv =
        ~w(my_app --cookbook cb_home@path:~/src/Gen/cb_home --recipe cb_home/lv/base --with phx.new)

      assert Enum.take(commands(argv), 2) == [
               {nil, "mix igniter.new my_app --no-git --yes --with phx.new"},
               {"/work/my_app",
                "mix composer_new.install 'composer@~> 0.3,cb_home@path:/home/me/src/Gen/cb_home' " <>
                  "--only dev,test --yes"}
             ]

      # The commit message keeps the path as typed.
      assert {_, "git commit --quiet -m " <> message} = Enum.at(commands(argv), 4)
      assert message =~ "cb_home@path:~/src/Gen/cb_home"
    end

    test "a base that is a package (the gen_astral case)" do
      argv =
        ~w(my_blog --cookbook cb_home@path:~/src/Gen/cb_home --recipe cb_home/astral/min) ++
          ~w(--install astral@path:~/src/Fork/astral)

      assert Enum.take(commands(argv), 3) == [
               {nil, "mix igniter.new my_blog --no-git --yes"},
               {"/work/my_blog",
                "mix composer_new.install astral@path:/home/me/src/Fork/astral --yes"},
               {"/work/my_blog",
                "mix composer_new.install 'composer@~> 0.3,cb_home@path:/home/me/src/Gen/cb_home' " <>
                  "--only dev,test --yes"}
             ]

      assert List.last(commands(argv)) ==
               {"/work/my_blog", "mix composer.recipe.run cb_home/astral/min"}
    end

    test "--recipe-args pass through to composer.recipe.run, split as a shell would" do
      argv = ["my_app", "--recipe", "cb_lab/phx/saas", "--recipe-args=--oban-pro --gigalixir"]

      assert List.last(commands(argv)) ==
               {"/work/my_app", "mix composer.recipe.run cb_lab/phx/saas --oban-pro --gigalixir"}

      argv = [
        "my_app",
        "--recipe",
        "cb_lab/phx/saas",
        "--recipe-args",
        "--title 'My App' --reset"
      ]

      assert List.last(build!(argv).commands).args ==
               ["composer.recipe.run", "cb_lab/phx/saas", "--title", "My App", "--reset"]
    end
  end

  test "--cookbook without --recipe installs the cookbook but runs no recipe" do
    commands = commands(~w(my_app --cookbook cb_lab@github:o/cb_lab))
    assert length(commands) == 5
    refute Enum.any?(commands, &match?({_, "mix composer.recipe.run" <> _}, &1))

    assert Enum.at(commands, 1) ==
             {"/work/my_app",
              "mix composer_new.install 'composer@~> 0.3,cb_lab@github:o/cb_lab' " <>
                "--only dev,test --yes"}

    assert build!(~w(my_app --cookbook cb_lab)).summary.recipe == nil
  end

  test "several cookbooks, in order, then the one --recipe implies" do
    plan = build!(~w(my_app --cookbook cb_a@path:../a --cookbook cb_b --recipe cb_c/lv/base))
    assert plan.summary.deps == ["composer@~> 0.3", "cb_a@path:/a", "cb_b", "cb_c"]

    assert [
             %{name: "cb_a", hex?: false, implied?: false},
             %{name: "cb_b", hex?: true, implied?: false, source: "hex, latest"},
             %{name: "cb_c", hex?: true, implied?: true}
           ] = plan.summary.cookbooks
  end

  test "a --recipe cookbook given with --cookbook comes from there" do
    plan = build!(["my_app", "--recipe", "cb_a/lv/base", "--cookbook", "cb_a@~> 0.2"])
    assert plan.summary.deps == ["composer@~> 0.3", "cb_a@~> 0.2"]
    assert [%{name: "cb_a", hex?: true, implied?: false}] = plan.summary.cookbooks
  end

  test "no --recipe and no --cookbook installs only composer and runs no recipe" do
    assert commands(~w(my_app)) ==
             [
               {nil, "mix igniter.new my_app --no-git --yes"},
               {"/work/my_app",
                "mix composer_new.install 'composer@~> 0.3' --only dev,test --yes"}
             ] ++ record("/work/my_app", "mix composer.new my_app")
  end

  test "--reset removes APP first" do
    assert [{:rm_rf, "/work/my_app"}, {nil, "mix igniter.new my_app" <> _} | _] =
             commands(~w(my_app --recipe cb_std/debug/echo --reset))

    assert [{:rm_rf, "/tmp/x"} | _] = commands(~w(/tmp/x --reset))
  end

  test "version requirements are kept, in every package" do
    argv =
      ["my_app", "--cookbook", "cb_lab@~> 0.4", "--composer", "~> 0.3"] ++
        ["--install", "jason@>= 1.4.0", "--extra-dep", "cb_more@~> 1.2"]

    assert [_create, base, dev | _] = commands(argv)
    assert base == {"/work/my_app", "mix composer_new.install 'jason@>= 1.4.0' --yes"}

    assert dev ==
             {"/work/my_app",
              "mix composer_new.install 'composer@~> 0.3,cb_lab@~> 0.4,cb_more@~> 1.2' " <>
                "--only dev,test --yes"}
  end

  test "--extra-dep, given twice" do
    plan =
      build!(
        ~w(my_app --recipe cb_lab/lv/base --extra-dep cb_more@path:../more --extra-dep=jason)
      )

    assert plan.summary.deps == ["composer@~> 0.3", "cb_lab", "cb_more@path:/more", "jason"]
  end

  describe "--igniter-local is relative to APP's parent" do
    test "absolute" do
      assert {nil, "mix igniter.new my_app --no-git --yes --local ../home/me/src/Fork/igniter"} =
               hd(commands(~w(my_app --igniter-local /home/me/src/Fork/igniter)))
    end

    test "~" do
      assert {nil, "mix igniter.new my_app --no-git --yes --local ../home/me/src/Fork/igniter"} =
               hd(commands(~w(my_app --igniter-local ~/src/Fork/igniter)))
    end

    test "with APP in another directory" do
      assert {nil, "mix igniter.new /tmp/x --no-git --yes --local ../home/me/src/Fork/igniter"} =
               hd(commands(~w(/tmp/x --igniter-local ~/src/Fork/igniter)))

      assert {nil, "mix igniter.new apps/x --no-git --yes --local ../../home/me/fork"} =
               hd(commands(~w(apps/x --igniter-local ~/fork)))
    end
  end

  test "the default composer requirement is ~> MAJOR.MINOR" do
    assert Plan.default_composer("0.3.0") == "~> 0.3"
    assert Plan.default_composer("1.2.3") == "~> 1.2"
    assert Plan.default_composer("1.0.0-rc.1") == "~> 1.0"
  end

  test "--composer path: is made absolute" do
    plan = build!(~w(my_app --composer path:../composer))
    assert plan.summary.deps == ["composer@path:/composer"]
    refute plan.summary.default_composer?
  end

  test "cb_std/ installs no cookbook" do
    plan = build!(~w(my_app --recipe cb_std/debug/echo))
    assert plan.summary.deps == ["composer@~> 0.3"]
    assert plan.summary.recipe == "cb_std/debug/echo"
    assert plan.summary.cookbooks == []
  end

  test "the summary" do
    plan = build!(~w(/tmp/x --recipe cb_lab/lv/base --with phx.new --with-args=--no-ecto))

    assert %{
             app: "x",
             dir: "/tmp/x",
             cookbooks: [%{name: "cb_lab", source: "hex, latest; named by --recipe"}],
             recipe: "cb_lab/lv/base",
             base: "phx.new --no-ecto",
             install: [],
             default_composer?: true
           } = plan.summary
  end

  describe "errors" do
    test "--recipe" do
      build = &Plan.build(["my_app", "--recipe", &1], @env)

      assert {:error,
              "--recipe: Invalid reference \"lv/base\": a recipe address is COOKBOOK/" <> _} =
               build.("lv/base")

      assert {:error, "--recipe: Invalid reference \"/lv/base\": a cookbook-root address" <> _} =
               build.("/lv/base")

      assert {:error, "--recipe: Invalid reference \"cb_std/debug/echo@0.3\": cb_std ships" <> _} =
               build.("cb_std/debug/echo@0.3")

      assert {:error, "--recipe: Invalid reference \"hex:oban\": hex: names a package" <> _} =
               build.("hex:oban")

      assert {:error, "--recipe: Invalid reference \"cb_lab/lv/base@0.3\": " <> why} =
               build.("cb_lab/lv/base@0.3")

      assert why =~ "--cookbook cb_lab@0.3"
    end

    test "--cookbook" do
      assert {:error, "--cookbook: Invalid package \"Cb\"" <> _} =
               Plan.build(~w(my_app --cookbook Cb), @env)

      assert {:error, "--cookbook: cb_std ships with composer" <> _} =
               Plan.build(~w(my_app --cookbook cb_std), @env)

      assert {:error, "--cookbook cb_a is given more than once"} =
               Plan.build(~w(my_app --cookbook cb_a --cookbook cb_a@path:../a), @env)

      assert {:error, "--extra-dep cb_a@1.0: cb_a is a cookbook" <> _} =
               Plan.build(~w(my_app --cookbook cb_a --extra-dep cb_a@1.0), @env)
    end

    test "a bad app name" do
      assert {:error, "\"MyApp\" is not a valid app name" <> _} = Plan.build(~w(MyApp), @env)

      assert {:error, "\"my-app\" is not a valid app name" <> _} =
               Plan.build(~w(/tmp/my-app), @env)
    end

    test "a bad --install or --extra-dep package" do
      assert {:error, "--install: Invalid package \"astral@svn:x\": Invalid source" <> _} =
               Plan.build(~w(my_app --install astral@svn:x), @env)

      assert {:error, "--extra-dep: Invalid package \"Jason\": package names" <> _} =
               Plan.build(~w(my_app --extra-dep Jason), @env)
    end

    test "a bad --composer source" do
      assert {:error, "--composer: Invalid source \"svn:x\"" <> _} =
               Plan.build(~w(my_app --composer svn:x), @env)
    end
  end
end
