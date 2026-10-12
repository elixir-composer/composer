defmodule Mix.Tasks.Composer.Git.Commit do
  @moduledoc false
  # Internal: queued by mix composer.recipe.run to run after its changes are applied.
  #
  #     mix composer.git.commit --message-file PATH
  #
  # Stages everything, commits with the message in PATH, then deletes PATH.
  # A run that changed nothing is reported, not treated as a failure.

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: [message_file: :string, yes: :boolean])

    file = opts[:message_file] || Mix.raise("Usage: mix composer.git.commit --message-file PATH")

    try do
      case Composer.Git.commit(File.cwd!(), file) do
        {:ok, _output} ->
          subject = file |> File.read!() |> String.split("\n", parts: 2) |> hd()
          Mix.shell().info("composer: committed \"#{subject}\"")

        :nothing_to_commit ->
          Mix.shell().info("composer: nothing to commit, the recipe made no changes")

        {:error, output} ->
          Mix.raise("composer: git commit failed:\n\n" <> output)
      end
    after
      File.rm(file)
    end
  end
end
