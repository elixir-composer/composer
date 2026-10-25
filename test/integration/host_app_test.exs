defmodule Composer.Integration.HostAppTest do
  # Builds a real host app with composer and a cookbook-shipping dependency
  # (test/fixtures/fake_dep) as path deps, then drives composer's tasks in
  # it. It compiles every dependency, so it only runs with:
  #
  #     mix test --include integration
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @root File.cwd!()

  setup %{tmp_dir: dir} do
    app = Path.join(dir, "host_app")
    File.mkdir_p!(Path.join(app, "lib"))
    File.cp!(Path.join(@root, "mix.lock"), Path.join(app, "mix.lock"))

    File.write!(Path.join(app, "mix.exs"), """
    defmodule HostApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :host_app,
          version: "0.1.0",
          deps_path: #{inspect(Path.join(@root, "deps"))},
          deps: deps()
        ]
      end

      # A function, as in a phx.new app, so hex: installs can edit it.
      defp deps do
        [
          {:composer, path: #{inspect(@root)}},
          {:fake_dep, path: #{inspect(Path.join(@root, "test/fixtures/fake_dep"))}}
        ]
      end
    end
    """)

    File.write!(Path.join(app, "lib/host_app.ex"), "defmodule HostApp do\nend\n")
    %{app: app}
  end

  defp mix(app, args) do
    System.cmd("mix", args, cd: app, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
  end

  defp mix!(app, args) do
    {output, status} = mix(app, args)
    assert status == 0, "mix #{Enum.join(args, " ")} failed:\n\n#{output}"
    output
  end

  test "a dependency's cookbook is discovered and runs; generated files pass lint",
       %{app: app} do
    # The dep's cookbook compiles inside its own project, so its name is
    # checked against :fake_dep.
    mix!(app, ["compile"])

    cookbooks = mix!(app, ["composer.cookbook.list", "--json"])
    assert cookbooks =~ ~s("name": "fake_dep")

    help = mix!(app, ["help"])
    refute help =~ "steps."
    refute help =~ "fake_dep"
    assert help =~ "mix composer.step.run"

    mix!(app, ["composer.step.run", "fake_dep:hi", "--yes"])
    assert File.read!(Path.join(app, "hi.txt")) == "hi from host_app\n"

    mix!(app, ["composer.gen.cookbook", "--yes"])

    # Re-running a generator leaves existing files alone, including ones it
    # has not read yet.
    recipe = Path.join(app, "lib/composer/host_app/recipes/app.exs")
    mine = ~s([default: [shortdoc: "Mine", steps: ["fake_dep:hi"]]]\n)
    File.write!(recipe, mine)
    mix!(app, ["composer.gen.cookbook", "--yes"])
    assert File.read!(recipe) == mine
    mix!(app, ["composer.gen.step", "tools/thing", "--yes"])
    mix!(app, ["composer.gen.recipe", "tools/extra", "--yes"])
    mix!(app, ["composer.gen.recipe", "tools/more", "--yes"])
    mix!(app, ["composer.cookbook.manifest"])
    assert mix!(app, ["composer.cookbook.lint"]) =~ "Cookbook host_app is valid."

    steps = mix!(app, ["composer.step.list", "--cookbook", "host_app"])
    assert steps =~ "host_app:tools:thing"

    list = mix!(app, ["composer.recipe.list", "host_app"])
    assert list =~ ~r/host_app\/app\/default\s+Mine/
    assert list =~ "host_app/tools/more"

    # A root address is the project's own cookbook.
    mix!(app, ["composer.recipe.run", "/app/default", "--yes", "--no-commit"])
  end

  test "composer compiles cleanly in a host", %{app: app} do
    mix!(app, ["compile"])
    output = mix!(app, ["deps.compile", "composer", "--force"])
    refute output =~ "warning"
  end

  test "--json output parses on a stale build; a compile error still fails", %{app: app} do
    mix!(app, ["compile"])

    # stderr is not captured, so compiler warnings there don't count.
    list_json = fn env ->
      System.cmd("mix", ["composer.recipe.list", "--json"],
        cd: app,
        env: [{"MIX_ENV", "dev"} | env]
      )
    end

    File.write!(Path.join(app, "lib/host_app.ex"), "defmodule HostApp do\n  def x, do: 1\nend\n")
    {output, 0} = list_json.([])
    assert %{"recipes" => [_ | _]} = Jason.decode!(output)

    # MIX_QUIET silences the Mix shell, but not the JSON.
    {output, 0} = list_json.([{"MIX_QUIET", "1"}])
    assert %{"recipes" => [_ | _]} = Jason.decode!(output)

    File.write!(Path.join(app, "lib/host_app.ex"), "defmodule HostApp do\n")
    {_output, status} = list_json.([])
    assert status != 0
  end

  test "a recipe in a path-dep cookbook's chapter uses a sibling and takes a declared flag",
       %{app: app} do
    chapter = Path.join(@root, "test/fixtures/fake_dep/lib/composer/fake_dep/recipes/mine.exs")

    # Compiling has work to do, yet stdout holds nothing but the JSON:
    # MIX_QUIET silences the dependencies Mix compiles before the task can
    # start; the task compiles the project quietly itself.
    lint_json = fn env ->
      {json, 0} =
        System.cmd("mix", ["composer.cookbook.lint", "--format", "json", "--file", chapter],
          cd: app,
          env: [{"MIX_ENV", "dev"} | env]
        )

      Jason.decode!(json)
    end

    assert lint_json.([{"MIX_QUIET", "1"}]) == []
    File.write!(Path.join(app, "lib/host_app.ex"), "defmodule HostApp do\n  def x, do: 1\nend\n")
    assert lint_json.([]) == []

    mix!(app, ["compile"])
    assert mix!(app, ["composer.cookbook.lint", "--file", chapter]) =~ "mine.exs is valid."

    show = mix!(app, ["composer.recipe.show", "fake_dep/mine/app"])
    assert show =~ ~r/--ignore\s+Add macOS files/
    assert show =~ "fake_dep:hi  [fake_dep/mine/base]"

    {output, status} = mix(app, ["composer.recipe.run", "fake_dep/mine/app", "--nope"])
    assert status != 0
    assert output =~ "Unknown flag --nope"

    mix!(app, ["composer.recipe.run", "fake_dep/mine/app", "--ignore", "--yes", "--no-commit"])
    assert File.read!(Path.join(app, "hi.txt")) == "hi from host_app\n"
    assert File.exists?(Path.join(app, ".gitignore"))
  end

  test "a hex: path source is added to mix.exs and its installer gets the argv",
       %{app: app} do
    installer = Path.join(@root, "test/fixtures/fake_installer")
    mix!(app, ["compile"])

    output =
      mix!(app, [
        "composer.step.run",
        "hex:fake_installer@path:#{installer}",
        "--yes",
        "--",
        "--greeting",
        "hi"
      ])

    assert output =~
             "hex:fake_installer (path #{installer}) --greeting hi — fake_installer.install"

    # One fetch for the run.
    assert length(String.split(output, "fetching deps \e[32m✔")) == 2

    # Igniter writes a keyword dep with brackets; compare the data.
    assert File.read!(Path.join(app, "mix.exs"))
           |> String.replace(~r/\s+/, " ")
           |> String.contains?(
             ~s({:fake_installer, [path: #{inspect(installer)}, override: true]})
           )

    # The installer ran in this run, with the argv and exactly one --yes.
    assert File.read!(Path.join(app, "installed.txt")) == "greeting=hi yes=1\n"
  end
end
