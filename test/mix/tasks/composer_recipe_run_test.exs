defmodule Mix.Tasks.Composer.Recipe.RunTest do
  # Changes the VM's working directory (the git checks read File.cwd!/0) and
  # the :composer application env.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Composer.Test.GitHelpers
  import Composer.Test.Cookbooks

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
    book = Path.join(dir, "mine")
    File.mkdir_p!(Path.join(book, "recipes"))

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

    File.write!(Path.join([book, "recipes", "t.exs"]), "[\n#{entries}\n]\n")

    app = Path.join(dir, "app")
    File.mkdir_p!(app)
    init_repo!(app)

    cwd = File.cwd!()
    File.cd!(app)

    Application.put_env(:composer, :discovery,
      modules: [Composer.FakeBook],
      cookbooks: [code_cookbook(book)]
    )

    on_exit(fn ->
      File.cd!(cwd)
      Application.delete_env(:composer, :discovery)
      Application.delete_env(:composer, :runner)
      clean_message_files()
    end)

    %{app: app}
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

  test "applies the resolved recipe" do
    run(["t/app"])
    |> assert_changed(".gitignore")
    |> assert_unchanged("mix.exs")
  end

  test "hands the runner the resolved, active internal steps" do
    Application.put_env(:composer, :runner, RecordingRunner)

    run(["t/cookbook", "--no-commit"])

    assert_received {:steps,
                     [
                       {:module, Composer.FakeBook.Steps.Hello},
                       {:module, Composer.Core.Steps.Setup.Gitignore}
                     ]}

    run(["t/app", "--no-commit", "--force-drop"])

    assert_received {:steps,
                     [
                       {:module, Composer.Core.Steps.Setup.Gitignore},
                       {:module, Composer.Core.Steps.Ecto.ForceDrop},
                       {:queue, "foo.bar", []}
                     ]}
  end

  test "a flagged step is skipped without its flag and applied with it" do
    assert_unchanged(run(["t/app"]), "mix.exs")

    run(["t/app", "--force-drop"])
    |> assert_has_patch(
      "mix.exs",
      ~S(+ |    ["ecto.reset": ["ecto.drop --force-drop", "ecto.setup"]])
    )
  end

  test "a gated use is skipped without its flag and applied with it" do
    run(["t/gated"])
    |> assert_changed(".gitignore")
    |> assert_unchanged("mix.exs")

    run(["mine:t/gated", "--deploy"])
    |> assert_has_patch(
      "mix.exs",
      ~S(+ |    ["ecto.reset": ["ecto.drop --force-drop", "ecto.setup"]])
    )
  end

  test "queues the commit last, with the message" do
    igniter = run(["t/app", "--force-drop"])

    assert [{"foo.bar", ["--yes"]}, {"composer.git.commit", ["--message-file", file]}] =
             igniter.tasks

    assert File.read!(file) == """
           composer: apply recipe mine:t/app

           Flags: --force-drop

           Steps:
           1. core:setup/gitignore [mine:t/base]
           2. core:ecto/force_drop [mine:t/app]
           3. {:queue, "foo.bar", []} [mine:t/app]
           """
  end

  test "the message lists only steps that ran" do
    [["--message-file", file]] = run(["t/app"]) |> commit_tasks()
    refute File.read!(file) =~ "force_drop"
    assert File.read!(file) =~ "Flags: (none)"
  end

  test "a dry run queues the commit but writes no message file" do
    [["--message-file", file]] = run(["t/app", "--dry-run"]) |> commit_tasks()
    refute File.exists?(file)
  end

  test "stale message files are swept" do
    stale = Path.join(System.tmp_dir!(), "composer-commit-stale.txt")
    File.write!(stale, "x")
    File.touch!(stale, System.os_time(:second) - 7200)

    run(["t/app"])
    refute File.exists?(stale)
  end

  test "--no-commit queues no commit" do
    igniter = run(["t/app", "--no-commit"])
    assert commit_tasks(igniter) == []
    assert_changed(igniter, ".gitignore")
  end

  test "refuses a dirty tree, unless --no-commit", %{app: app} do
    File.write!(Path.join(app, "untracked.txt"), "x")

    assert_raise Mix.Error, ~r/uncommitted changes/, fn -> run(["t/app"]) end
    assert_changed(run(["t/app", "--no-commit"]), ".gitignore")
  end

  test "refuses outside a git repo, unless --no-commit" do
    outside = Path.join(System.tmp_dir!(), "composer-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.cd!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert_raise Mix.Error, ~r/git init/, fn -> run(["t/app"]) end
    assert_changed(run(["t/app", "--no-commit"]), ".gitignore")
  end

  test "cookbook steps run as their module" do
    run(["t/cookbook"])
    |> assert_creates("hello.txt", "hello\n")
    |> assert_changed(".gitignore")
  end

  test "a cookbook step's if: becomes a flag" do
    assert Mix.Tasks.Composer.Recipe.Run.info(["t/cookbook_gated"], nil).schema[
             :hello
           ] == :boolean

    refute_creates(run(["t/cookbook_gated"]), "hello.txt")
    assert_creates(run(["t/cookbook_gated", "--hello"]), "hello.txt")
  end

  test "a missing step fails before anything runs, naming the recipe" do
    assert_raise Mix.Error,
                 ~r/In recipe mine:t\/cookbook_missing: no step matches "fake_book:nope"/,
                 fn ->
                   run(["t/cookbook_missing"])
                 end
  end

  test "an old step form is rejected with the new syntax" do
    assert_raise Mix.Error, ~r/Write it as "gitignore" instead/, fn ->
      run(["t/legacy"])
    end
  end

  test "an unmet requires stops the run" do
    assert_raise Mix.Error, ~r/composer-fixture-missing-tool/, fn ->
      run(["t/tool", "--no-commit"])
    end
  end

  test "info/2 publishes a boolean per flag" do
    info = Mix.Tasks.Composer.Recipe.Run.info(["--force-drop", "t/app"], nil)
    assert info.positional == [:recipe]
    assert info.schema[:force_drop] == :boolean
    assert info.schema[:no_commit] == :boolean
    assert info.aliases == []

    gated = Mix.Tasks.Composer.Recipe.Run.info(["t/gated"], nil)
    assert gated.schema[:deploy] == :boolean

    assert Mix.Tasks.Composer.Recipe.Run.info([], nil).schema == [no_commit: :boolean]
  end

  test "an undeclared --flag is rejected, naming the declared ones" do
    assert_raise Mix.Error,
                 ~r/Unknown flag --deplyo for recipe mine:t\/gated. Its flags: --deploy/,
                 fn ->
                   run(["t/gated", "--deplyo"])
                 end

    assert_raise Mix.Error, ~r/Unknown flag --force-drop .* It declares no flags/, fn ->
      run(["t/base", "--force-drop"])
    end

    # Igniter's own options and the task's are fine.
    assert_changed(run(["t/base", "--no-commit", "--verbose"]), ".gitignore")
  end

  test "a flag declared by a used recipe is accepted" do
    assert Mix.Tasks.Composer.Recipe.Run.info(["t/uses_gated"], nil).schema[:hello] ==
             :boolean

    assert_creates(run(["t/uses_gated", "--hello"]), "hello.txt")
  end

  test "flags that collide with task options are rejected" do
    assert_raise Mix.Error, ~r/Flag :yes is reserved/, fn ->
      Mix.Tasks.Composer.Recipe.Run.info(["t/reserved"], nil)
    end
  end

  test "an unknown recipe raises with suggestions" do
    assert_raise Mix.Error, ~r/no recipe matches "t\/bsae".*mine:t\/base/s, fn ->
      run(["t/bsae"])
    end
  end
end
