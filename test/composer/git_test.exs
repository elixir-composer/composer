defmodule Composer.GitTest do
  # File.cd! in the commit task tests changes the whole VM's cwd.
  use ExUnit.Case, async: false

  import Composer.Test.GitHelpers

  alias Composer.Git

  @moduletag :tmp_dir

  describe "status/1" do
    test "reports :not_a_repo, :clean and :dirty", %{tmp_dir: dir} do
      # tmp_dir lives inside this project's repo, so use one outside it.
      outside = Path.join(System.tmp_dir!(), "composer-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      assert Git.status(outside) == :not_a_repo

      init_repo!(dir)
      assert Git.status(dir) == :clean

      File.write!(Path.join(dir, "untracked.txt"), "x")
      assert Git.status(dir) == :dirty
    end

    test "ignored files are not dirty", %{tmp_dir: dir} do
      init_repo!(dir)
      File.write!(Path.join(dir, ".gitignore"), "*.log\n")
      git!(dir, ["add", "-A"])
      git!(dir, ["commit", "--quiet", "-m", "ignore"])
      File.write!(Path.join(dir, "debug.log"), "x")
      assert Git.status(dir) == :clean
    end
  end

  describe "message/3" do
    @entries [
      %{label: "core:phx/remove_daisy_ui", origin: "local:phoenix_cleanup"},
      %{label: "core:oban_pro", origin: "local:jobs"},
      %{label: "core:phx/remove_topbar", origin: nil}
    ]

    test "builds the subject and plain-line body" do
      message =
        Git.message(
          "local:standard_app",
          %{config: "/c/composer", flags: [:oban_pro]},
          @entries
        )

      assert message == """
             composer: apply recipe local:standard_app

             Config: /c/composer
             Flags: --oban-pro

             Steps:
             1. core:phx/remove_daisy_ui [local:phoenix_cleanup]
             2. core:oban_pro [local:jobs]
             3. core:phx/remove_topbar [command line]
             """

      refute message =~ ~r/^\s*[-*•] /m
    end

    test "keeps the subject under 72 characters" do
      long = String.duplicate("very_long_recipe_name_", 5)
      [subject | _] = String.split(Git.message(long, %{config: "c", flags: []}, []), "\n")

      assert String.length(subject) < 72
      assert String.ends_with?(subject, "...")
    end

    test "shows (none) for no flags and no steps" do
      message = Git.message("local:empty", %{config: "c", flags: []}, [])
      assert message =~ "Flags: (none)"
      assert message =~ "Steps:\n(none)"
    end
  end

  describe "mix composer.git.commit" do
    setup %{tmp_dir: dir} do
      init_repo!(dir)
      file = Path.join(dir, "../msg-#{System.unique_integer([:positive])}.txt")
      File.write!(file, "composer: apply recipe x\n\nSteps:\n1. core:setup/credo [x]\n")
      %{msg_file: file}
    end

    test "commits everything with the message and deletes the file", %{
      tmp_dir: dir,
      msg_file: file
    } do
      File.write!(Path.join(dir, "new.txt"), "x")

      ExUnit.CaptureIO.capture_io(fn ->
        File.cd!(dir, fn -> Mix.Tasks.Composer.Git.Commit.run(["--message-file", file]) end)
      end)

      assert git!(dir, ["log", "-1", "--format=%B"]) =~ "composer: apply recipe x\n\nSteps:"
      assert git!(dir, ["show", "--name-only", "--format="]) =~ "new.txt"
      assert Git.status(dir) == :clean
      refute File.exists?(file)
    end

    test "tolerates nothing to commit", %{tmp_dir: dir, msg_file: file} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          File.cd!(dir, fn -> Mix.Tasks.Composer.Git.Commit.run(["--message-file", file]) end)
        end)

      assert output =~ "nothing to commit"
      assert git!(dir, ["rev-list", "--count", "HEAD"]) == "1\n"
    end
  end
end
