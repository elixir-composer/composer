defmodule Mix.Tasks.Composer.Recipe.RunTest do
  # Changes the VM's working directory (the git checks read File.cwd!/0) and
  # the :composer application env.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Composer.Test.GitHelpers

  @moduletag :tmp_dir

  @recipes %{
    "base" => ~s(["core:setup/gitignore"]),
    "deploy" => ~s(["core:ecto/force_drop"]),
    "app" =>
      ~s([{:use, "base"}, {"core:ecto/force_drop", if: :force_drop}, {:queue, "foo.bar", []}]),
    "gated" => ~s([{:use, "base"}, {:use, "deploy", if: :deploy}]),
    "reserved" => ~s([{"core:setup/gitignore", if: :yes}]),
    "cookbook" => ~s(["fake_book:hello", "setup/gitignore"]),
    "cookbook_gated" => ~s([{"fake_book:hello", if: :hello}]),
    "cookbook_missing" => ~s(["fake_book:nope"]),
    "legacy" => "[{:gen, :gitignore}]",
    "tool" => ~s(["fake_book:needs_tool"]),
    "uses_gated" => ~s([{:use, "cookbook_gated"}])
  }

  @mix_exs """
  defmodule Test.MixProject do
    use Mix.Project

    def project do
      [app: :test, version: "0.1.0", deps: [], aliases: aliases()]
    end

    defp aliases do
      ["ecto.reset": ["ecto.drop", "ecto.setup"]]
    end
  end
  """

  defmodule RecordingRunner do
    @moduledoc false
    def run(igniter, steps, _opts) do
      send(self(), {:steps, steps})
      igniter
    end
  end

  setup %{tmp_dir: dir} do
    config = Path.join(dir, "config")
    File.mkdir_p!(Path.join(config, "recipes"))

    # One group, t, declaring every flag its recipes use (except legacy,
    # which does not evaluate as a step list).
    entries =
      Enum.map_join(@recipes, ",\n", fn {name, body} ->
        flags =
          case Composer.Recipe.validate(elem(Code.eval_string(body), 0), name) do
            {:ok, steps} ->
              for flag <- Composer.Recipe.if_flags(steps), do: {flag, "The #{flag} flag"}

            _ ->
              []
          end

        "  #{name}: [shortdoc: #{inspect(name)}, flags: #{inspect(flags)}, steps: #{body}]"
      end)

    File.write!(Path.join([config, "recipes", "t.exs"]), "[\n#{entries}\n]\n")

    app = Path.join(dir, "app")
    File.mkdir_p!(app)
    init_repo!(app)

    cwd = File.cwd!()
    File.cd!(app)
    Application.put_env(:composer, :discovery, modules: [Composer.FakeBook])

    on_exit(fn ->
      File.cd!(cwd)
      Application.delete_env(:composer, :discovery)
      Application.delete_env(:composer, :runner)
      clean_message_files()
    end)

    %{config: config, app: app}
  end

  defp run(argv) do
    test_project(files: %{"mix.exs" => @mix_exs})
    |> Igniter.compose_task("composer.recipe.run", argv)
  end

  defp assert_changed(igniter, path) do
    source = Rewrite.source!(igniter.rewrite, path)
    assert Rewrite.Source.updated?(source), "expected #{path} to be changed"
    igniter
  end

  defp commit_tasks(igniter) do
    for {"composer.git.commit", argv} <- igniter.tasks, do: argv
  end

  defp clean_message_files do
    System.tmp_dir!()
    |> Path.join("composer-commit-*.txt")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  test "applies the resolved recipe", %{config: config} do
    run(["t/app", "-c", config])
    |> assert_changed(".gitignore")
    |> assert_unchanged("mix.exs")
  end

  test "hands the runner the resolved, active internal steps", %{config: config} do
    Application.put_env(:composer, :runner, RecordingRunner)

    run(["t/cookbook", "-c", config, "--no-commit"])

    assert_received {:steps,
                     [
                       {:module, Composer.FakeBook.Steps.Hello},
                       {:module, Composer.Core.Steps.Setup.Gitignore}
                     ]}

    run(["t/app", "-c", config, "--no-commit", "--force-drop"])

    assert_received {:steps,
                     [
                       {:module, Composer.Core.Steps.Setup.Gitignore},
                       {:module, Composer.Core.Steps.Ecto.ForceDrop},
                       {:queue, "foo.bar", []}
                     ]}
  end

  test "a flagged step is skipped without its flag and applied with it", %{config: config} do
    assert_unchanged(run(["t/app", "-c", config]), "mix.exs")

    run(["t/app", "-c", config, "--force-drop"])
    |> assert_has_patch(
      "mix.exs",
      ~S(+ |    ["ecto.reset": ["ecto.drop --force-drop", "ecto.setup"]])
    )
  end

  test "a gated use is skipped without its flag and applied with it", %{config: config} do
    run(["t/gated", "-c", config])
    |> assert_changed(".gitignore")
    |> assert_unchanged("mix.exs")

    run(["local:t/gated", "--config", config, "--deploy"])
    |> assert_has_patch(
      "mix.exs",
      ~S(+ |    ["ecto.reset": ["ecto.drop --force-drop", "ecto.setup"]])
    )
  end

  test "queues the commit last, with the message", %{config: config} do
    igniter = run(["t/app", "-c", config, "--force-drop"])

    assert [{"foo.bar", ["--yes"]}, {"composer.git.commit", ["--message-file", file]}] =
             igniter.tasks

    assert File.read!(file) == """
           composer: apply recipe local:t/app

           Config: #{config}
           Flags: --force-drop

           Steps:
           1. core:setup/gitignore [local:t/base]
           2. core:ecto/force_drop [local:t/app]
           3. {:queue, "foo.bar", []} [local:t/app]
           """
  end

  test "the message lists only steps that ran", %{config: config} do
    [["--message-file", file]] = run(["t/app", "-c", config]) |> commit_tasks()
    refute File.read!(file) =~ "force_drop"
    assert File.read!(file) =~ "Flags: (none)"
  end

  test "a dry run queues the commit but writes no message file", %{config: config} do
    [["--message-file", file]] = run(["t/app", "-c", config, "--dry-run"]) |> commit_tasks()
    refute File.exists?(file)
  end

  test "stale message files are swept", %{config: config} do
    stale = Path.join(System.tmp_dir!(), "composer-commit-stale.txt")
    File.write!(stale, "x")
    File.touch!(stale, System.os_time(:second) - 7200)

    run(["t/app", "-c", config])
    refute File.exists?(stale)
  end

  test "--no-commit queues no commit", %{config: config} do
    igniter = run(["t/app", "-c", config, "--no-commit"])
    assert commit_tasks(igniter) == []
    assert_changed(igniter, ".gitignore")
  end

  test "refuses a dirty tree, unless --no-commit", %{config: config, app: app} do
    File.write!(Path.join(app, "untracked.txt"), "x")

    assert_raise Mix.Error, ~r/uncommitted changes/, fn -> run(["t/app", "-c", config]) end
    assert_changed(run(["t/app", "-c", config, "--no-commit"]), ".gitignore")
  end

  test "refuses outside a git repo, unless --no-commit", %{config: config} do
    outside = Path.join(System.tmp_dir!(), "composer-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.cd!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert_raise Mix.Error, ~r/git init/, fn -> run(["t/app", "-c", config]) end
    assert_changed(run(["t/app", "-c", config, "--no-commit"]), ".gitignore")
  end

  test "cookbook steps run as their module", %{config: config} do
    run(["t/cookbook", "-c", config])
    |> assert_creates("hello.txt", "hello\n")
    |> assert_changed(".gitignore")
  end

  test "a cookbook step's if: becomes a flag", %{config: config} do
    assert Mix.Tasks.Composer.Recipe.Run.info(["t/cookbook_gated", "-c", config], nil).schema[
             :hello
           ] == :boolean

    refute_creates(run(["t/cookbook_gated", "-c", config]), "hello.txt")
    assert_creates(run(["t/cookbook_gated", "-c", config, "--hello"]), "hello.txt")
  end

  test "a missing step fails before anything runs, naming the recipe", %{config: config} do
    assert_raise Mix.Error,
                 ~r/In recipe local:t\/cookbook_missing: no step matches "fake_book:nope"/,
                 fn ->
                   run(["t/cookbook_missing", "-c", config])
                 end
  end

  test "an old step form is rejected with the new syntax", %{config: config} do
    assert_raise Mix.Error, ~r/Write it as "gitignore" instead/, fn ->
      run(["t/legacy", "-c", config])
    end
  end

  test "an unmet requires stops the run", %{config: config} do
    assert_raise Mix.Error, ~r/composer-fixture-missing-tool/, fn ->
      run(["t/tool", "-c", config, "--no-commit"])
    end
  end

  test "info/2 publishes a boolean per flag", %{config: config} do
    info = Mix.Tasks.Composer.Recipe.Run.info(["--force-drop", "t/app", "-c", config], nil)
    assert info.positional == [:recipe]
    assert info.schema[:force_drop] == :boolean
    assert info.schema[:no_commit] == :boolean
    assert info.aliases == [c: :config]

    gated = Mix.Tasks.Composer.Recipe.Run.info(["t/gated", "-c", config], nil)
    assert gated.schema[:deploy] == :boolean

    assert Mix.Tasks.Composer.Recipe.Run.info([], nil).schema == [
             config: :string,
             no_commit: :boolean
           ]
  end

  test "an undeclared --flag is rejected, naming the declared ones", %{config: config} do
    assert_raise Mix.Error,
                 ~r/Unknown flag --deplyo for recipe local:t\/gated. Its flags: --deploy/,
                 fn ->
                   run(["t/gated", "-c", config, "--deplyo"])
                 end

    assert_raise Mix.Error, ~r/Unknown flag --force-drop .* It declares no flags/, fn ->
      run(["t/base", "-c", config, "--force-drop"])
    end

    # Igniter's own options and the task's are fine.
    assert_changed(run(["t/base", "-c", config, "--no-commit", "--verbose"]), ".gitignore")
  end

  test "a flag declared by a used recipe is accepted", %{config: config} do
    assert Mix.Tasks.Composer.Recipe.Run.info(["t/uses_gated", "-c", config], nil).schema[:hello] ==
             :boolean

    assert_creates(run(["t/uses_gated", "-c", config, "--hello"]), "hello.txt")
  end

  test "flags that collide with task options are rejected", %{config: config} do
    assert_raise Mix.Error, ~r/Flag :yes is reserved/, fn ->
      Mix.Tasks.Composer.Recipe.Run.info(["t/reserved", "-c", config], nil)
    end
  end

  test "an unknown recipe raises with suggestions", %{config: config} do
    assert_raise Mix.Error, ~r/no recipe matches "t\/bsae".*local:t\/base/s, fn ->
      run(["t/bsae", "-c", config])
    end
  end
end
