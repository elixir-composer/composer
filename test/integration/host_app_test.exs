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
    File.mkdir_p!(Path.join(dir, "config"))
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
    %{app: app, config: Path.join(dir, "config")}
  end

  defp mix(app, config, args) do
    System.cmd("mix", args,
      cd: app,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "dev"}, {"COMPOSER_CONFIG", config}]
    )
  end

  defp mix!(app, config, args) do
    {output, status} = mix(app, config, args)
    assert status == 0, "mix #{Enum.join(args, " ")} failed:\n\n#{output}"
    output
  end

  test "a dependency's cookbook is discovered and runs; generated files pass lint",
       %{app: app, config: config} do
    # The dep's cookbook compiles inside its own project, so its name is
    # checked against :fake_dep.
    mix!(app, config, ["compile"])

    cookbooks = mix!(app, config, ["composer.cookbook.list", "--json"])
    assert cookbooks =~ ~s("name": "fake_dep")

    help = mix!(app, config, ["help"])
    refute help =~ "steps."
    refute help =~ "fake_dep"
    assert help =~ "mix composer.step.run"

    mix!(app, config, ["composer.step.run", "fake_dep:hi", "--yes"])
    assert File.read!(Path.join(app, "hi.txt")) == "hi from host_app\n"

    mix!(app, config, ["composer.gen.cookbook", "--yes"])

    # Re-running a generator leaves existing files alone, including ones it
    # has not read yet.
    recipe = Path.join(app, "lib/composer/host_app/recipes/app.exs")
    mine = ~s([default: [shortdoc: "Mine", steps: ["fake_dep:hi"]]]\n)
    File.write!(recipe, mine)
    mix!(app, config, ["composer.gen.cookbook", "--yes"])
    assert File.read!(recipe) == mine
    mix!(app, config, ["composer.gen.step", "tools/thing", "--yes"])
    mix!(app, config, ["composer.gen.recipe", "tools/extra", "--yes"])
    mix!(app, config, ["composer.gen.recipe", "tools/more", "--yes"])
    mix!(app, config, ["composer.cookbook.manifest"])
    assert mix!(app, config, ["composer.cookbook.lint"]) =~ "Cookbook host_app is valid."

    steps = mix!(app, config, ["composer.step.list", "--cookbook", "host_app"])
    assert steps =~ "host_app:tools/thing"

    list = mix!(app, config, ["composer.recipe.list", "host_app"])
    assert list =~ ~r/host_app:app\/default\s+Mine/
    assert list =~ "host_app:tools/more"

    # An unqualified recipe reference prefers the project's own cookbook.
    mix!(app, config, ["composer.recipe.run", "app/default", "--yes", "--no-commit"])
  end

  test "without gen_lsp: composer compiles cleanly and composer.lsp says what to add",
       %{app: app, config: config} do
    mix!(app, config, ["compile"])
    output = mix!(app, config, ["deps.compile", "composer", "--force"])
    refute output =~ "warning"

    {output, status} = mix(app, config, ["composer.lsp"])
    assert status != 0
    assert output =~ ~s({:gen_lsp, "~> 0.11.4", only: :dev})
  end

  test "a local grouped recipe uses a sibling and takes a declared flag",
       %{app: app, config: config} do
    File.mkdir_p!(Path.join(config, "recipes"))

    File.write!(Path.join(config, "recipes/mine.exs"), """
    [
      base: [shortdoc: "Says hi", steps: ["fake_dep:hi"]],
      app: [
        shortdoc: "Base, plus a .gitignore with --ignore",
        flags: [ignore: "Add macOS files to .gitignore"],
        steps: [{:use, "base"}, {"core:setup/gitignore", if: :ignore}]
      ]
    ]
    """)

    # Compiling has work to do, yet stdout holds nothing but the JSON:
    # MIX_QUIET silences the dependencies Mix compiles before the task can
    # start; the task compiles the project quietly itself.
    lint_json = fn env ->
      {json, 0} =
        System.cmd("mix", ["composer.cookbook.lint", "--local", "--format", "json"],
          cd: app,
          env: [{"MIX_ENV", "dev"}, {"COMPOSER_CONFIG", config}] ++ env
        )

      Jason.decode!(json)
    end

    assert lint_json.([{"MIX_QUIET", "1"}]) == []
    File.write!(Path.join(app, "lib/host_app.ex"), "defmodule HostApp do\n  def x, do: 1\nend\n")
    assert lint_json.([]) == []

    mix!(app, config, ["compile"])
    assert mix!(app, config, ["composer.cookbook.lint", "--local"]) =~ "are valid"

    show = mix!(app, config, ["composer.recipe.show", "local:mine/app"])
    assert show =~ ~r/--ignore\s+Add macOS files/
    assert show =~ "fake_dep:hi  [local:mine/base]"

    {output, status} = mix(app, config, ["composer.recipe.run", "local:mine/app", "--nope"])
    assert status != 0
    assert output =~ "Unknown flag --nope"

    mix!(app, config, ["composer.recipe.run", "local:mine/app", "--ignore", "--yes", "--no-commit"])
    assert File.read!(Path.join(app, "hi.txt")) == "hi from host_app\n"
    assert File.exists?(Path.join(app, ".gitignore"))
  end

  test "a hex: path source is added to mix.exs and its installer gets the argv",
       %{app: app, config: config} do
    installer = Path.join(@root, "test/fixtures/fake_installer")
    mix!(app, config, ["compile"])

    output =
      mix!(app, config, [
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
