defmodule Composer.Test.GitHelpers do
  @moduledoc false

  @doc "Initializes a git repo with one commit in `dir`."
  def init_repo!(dir) do
    git!(dir, ["init", "--quiet"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    git!(dir, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(dir, "README.md"), "hello\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", "Initial commit"])
    dir
  end

  def git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
