defmodule ComposerNew.Shell do
  @moduledoc """
  Prints a `ComposerNew.Plan`, or runs it.

  Each command is its own OS process, with its output streamed to the
  terminal. A child's stdin isn't a terminal, so a prompt would hang: every
  `mix` command in the plan gets `--yes`.
  """

  alias ComposerNew.{Command, Plan}

  @doc "Prints the plan's summary and its numbered commands."
  @spec print(Plan.t()) :: :ok
  def print(%Plan{summary: summary, commands: commands}) do
    rows =
      [
        {"app", "#{summary.app} (#{summary.dir})"},
        {"cookbook", summary.cookbook && "#{summary.cookbook} (#{summary.source})"},
        {"recipe", summary.recipe || "none"},
        {"base", summary.base},
        {"install", if(summary.install != [], do: Enum.join(summary.install, ", "))},
        {"dev deps", Enum.join(summary.deps, ", ")}
      ]

    lines =
      for {label, value} <- rows,
          value != nil,
          do: "  #{String.pad_trailing(label <> ":", 10)} #{value}"

    numbered =
      commands
      |> Enum.with_index(1)
      |> Enum.map(fn {command, n} -> "  #{n}. #{describe(command)}" end)

    IO.puts(
      Enum.join(["mix composer.new will create:" | lines] ++ ["", "Commands:" | numbered], "\n")
    )
  end

  @doc """
  Runs the plan's commands in order, stopping at the first that fails.
  Returns `:ok` or `{:error, command, status}`.
  """
  @spec run(Plan.t()) :: :ok | {:error, Command.t(), non_neg_integer()}
  def run(%Plan{commands: commands}) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      IO.puts("\n>>> " <> describe(command))

      case exec(command) do
        0 -> {:cont, :ok}
        status -> {:halt, {:error, command, status}}
      end
    end)
  end

  @doc "A plan step as a shell line, with the directory it runs in."
  @spec describe(Plan.step()) :: String.t()
  def describe({:rm_rf, dir}), do: "rm -rf " <> Command.escape(dir)
  def describe(%Command{cd: nil} = command), do: Command.to_string(command)

  def describe(%Command{cd: dir} = command),
    do: "(cd #{Command.escape(dir)} && #{Command.to_string(command)})"

  defp exec({:rm_rf, dir}) do
    File.rm_rf!(dir)
    0
  end

  defp exec(%Command{cmd: cmd, args: args, cd: dir}) do
    case System.find_executable(cmd) do
      nil ->
        IO.puts(:stderr, "#{cmd} is not on the PATH")
        127

      path ->
        opts = [into: IO.stream(:stdio, :line), stderr_to_stdout: true]
        opts = if dir, do: [{:cd, dir} | opts], else: opts
        {_stream, status} = System.cmd(path, args, opts)
        status
    end
  end
end
