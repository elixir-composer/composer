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
      argv = ~w(my_app cb_lab:lv/base --with phx.new --with-args=--no-ecto)

      assert commands(argv) ==
               [
                 {nil,
                  "mix igniter.new my_app --no-git --yes --with phx.new --with-args=--no-ecto"},
                 {"/work/my_app",
                  "mix composer_new.install 'composer@~> 0.3,cb_lab' --only dev,test --yes"}
               ] ++
                 record(
                   "/work/my_app",
                   "mix composer.new my_app cb_lab:lv/base --with phx.new --with-args=--no-ecto"
                 ) ++
                 [{"/work/my_app", "mix composer.recipe.run cb_lab:lv/base"}]
    end

    test "github, default branch" do
      argv = ~w(my_app cb_lab:lv/base@github:elixir-composer/cb_lab)

      assert Enum.at(commands(argv), 1) ==
               {"/work/my_app",
                "mix composer_new.install 'composer@~> 0.3,cb_lab@github:elixir-composer/cb_lab' " <>
                  "--only dev,test --yes"}

      assert List.last(commands(argv)) ==
               {"/work/my_app", "mix composer.recipe.run cb_lab:lv/base"}
    end

    test "github, pinned" do
      plan = build!(~w(my_app cb_lab:lv/base@github:elixir-composer/cb_lab@v0.3.0))

      assert plan.summary.deps == [
               "composer@~> 0.3",
               "cb_lab@github:elixir-composer/cb_lab@v0.3.0"
             ]

      assert plan.summary.source == "github:elixir-composer/cb_lab@v0.3.0"
      assert plan.summary.recipe == "cb_lab:lv/base"
    end

    test "local path, with phx.new (the gen_lv case)" do
      argv = ~w(my_app cb_home:lv/base@path:~/src/Gen/cb_home --with phx.new)

      assert Enum.take(commands(argv), 2) == [
               {nil, "mix igniter.new my_app --no-git --yes --with phx.new"},
               {"/work/my_app",
                "mix composer_new.install 'composer@~> 0.3,cb_home@path:/home/me/src/Gen/cb_home' " <>
                  "--only dev,test --yes"}
             ]

      # The commit message keeps the path as typed.
      assert {_, "git commit --quiet -m " <> message} = Enum.at(commands(argv), 4)
      assert message =~ "cb_home:lv/base@path:~/src/Gen/cb_home"
    end

    test "a base that is a package (the gen_astral case)" do
      argv =
        ~w(my_blog cb_home:astral/min@path:~/src/Gen/cb_home --install astral@path:~/src/Fork/astral)

      assert Enum.take(commands(argv), 3) == [
               {nil, "mix igniter.new my_blog --no-git --yes"},
               {"/work/my_blog",
                "mix composer_new.install astral@path:/home/me/src/Fork/astral --yes"},
               {"/work/my_blog",
                "mix composer_new.install 'composer@~> 0.3,cb_home@path:/home/me/src/Gen/cb_home' " <>
                  "--only dev,test --yes"}
             ]

      assert List.last(commands(argv)) ==
               {"/work/my_blog", "mix composer.recipe.run cb_home:astral/min"}
    end

    test "recipe flags pass through to composer.recipe.run" do
      assert List.last(commands(~w(my_app cb_lab:phx/saas --oban-pro --gigalixir))) ==
               {"/work/my_app", "mix composer.recipe.run cb_lab:phx/saas --oban-pro --gigalixir"}

      assert List.last(commands(~w(my_app cb_lab:phx/saas -- --reset))) ==
               {"/work/my_app", "mix composer.recipe.run cb_lab:phx/saas --reset"}
    end
  end

  test "--no-recipe creates, installs and records, but runs no recipe" do
    commands = commands(~w(my_app cb_lab:lv/base --no-recipe))
    assert length(commands) == 5
    refute Enum.any?(commands, &match?({_, "mix composer.recipe.run" <> _}, &1))
    assert build!(~w(my_app cb_lab:lv/base --no-recipe)).summary.recipe == nil
  end

  test "no REF installs only composer and runs no recipe" do
    assert commands(~w(my_app)) ==
             [
               {nil, "mix igniter.new my_app --no-git --yes"},
               {"/work/my_app",
                "mix composer_new.install 'composer@~> 0.3' --only dev,test --yes"}
             ] ++ record("/work/my_app", "mix composer.new my_app")
  end

  test "--reset removes APP first" do
    assert [{:rm_rf, "/work/my_app"}, {nil, "mix igniter.new my_app" <> _} | _] =
             commands(~w(my_app cb_std:debug/echo --reset))

    assert [{:rm_rf, "/tmp/x"} | _] = commands(~w(/tmp/x --reset))
  end

  test "version requirements are kept, in every package" do
    argv =
      ["my_app", "cb_lab:lv/base@~> 0.4", "--composer", "~> 0.3", "--install", "jason@>= 1.4.0"] ++
        ["--extra-dep", "cb_more@~> 1.2"]

    assert [_create, base, dev | _] = commands(argv)
    assert base == {"/work/my_app", "mix composer_new.install 'jason@>= 1.4.0' --yes"}

    assert dev ==
             {"/work/my_app",
              "mix composer_new.install 'composer@~> 0.3,cb_lab@~> 0.4,cb_more@~> 1.2' " <>
                "--only dev,test --yes"}
  end

  test "--extra-dep, given twice" do
    plan = build!(~w(my_app cb_lab:lv/base --extra-dep cb_more@path:../more --extra-dep=jason))
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

  test "cb_std: installs no cookbook" do
    plan = build!(~w(my_app cb_std:debug/echo))
    assert plan.summary.deps == ["composer@~> 0.3"]
    assert plan.summary.recipe == "cb_std:debug/echo"
    assert plan.summary.source == "ships with composer"
  end

  test "the summary" do
    plan = build!(~w(/tmp/x cb_lab:lv/base --with phx.new --with-args=--no-ecto))

    assert %{
             app: "x",
             dir: "/tmp/x",
             cookbook: "cb_lab",
             source: "hex, latest",
             recipe: "cb_lab:lv/base",
             base: "phx.new --no-ecto",
             install: [],
             default_composer?: true
           } = plan.summary
  end

  describe "errors" do
    test "refs" do
      assert {:error, "Invalid reference \"lv/base\": refs must name a cookbook" <> _} =
               Plan.build(~w(my_app lv/base), @env)

      assert {:error, "Invalid reference \"cb_std:debug/echo@0.3\": cb_std ships" <> _} =
               Plan.build(~w(my_app cb_std:debug/echo@0.3), @env)

      assert {:error, "Invalid reference \"hex:oban\": hex: names a package" <> _} =
               Plan.build(~w(my_app hex:oban), @env)
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
